import CryptoKit
import Foundation

final class UsageCollector {
    private enum RequestError: Error {
        case message(String)

        var description: String {
            switch self {
            case .message(let message): return message
            }
        }
    }

    private let fileManager = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private let oauthBeta = "oauth-2025-04-20"

    func discover() -> [UsageProfile] {
        var profiles: [UsageProfile] = []
        for directory in profileDirectories(prefix: ".claude") {
            profiles.append(claudeProfile(directory: directory))
        }
        for directory in profileDirectories(prefix: ".codex") {
            profiles.append(codexProfile(directory: directory))
        }
        for directory in profileDirectories(prefix: ".grok") {
            profiles.append(grokProfile(directory: directory))
        }
        return annotateSameAccount(profiles)
    }

    /// Limits belong to an account, not to a slot. Every slot stays visible as its own row -
    /// slots are the fixed thing accounts get mounted onto - but a slot holding the same account
    /// as an earlier one is marked, since it has no quota of its own to offer.
    private func annotateSameAccount(_ profiles: [UsageProfile]) -> [UsageProfile] {
        var annotated = profiles
        var firstSlotByAccount: [String: String] = [:]
        for index in annotated.indices {
            guard let key = annotated[index].accountKey else { continue }
            let identity = "\(annotated[index].engine.rawValue):\(key)"
            let slot = SlotNames.name(
                for: annotated[index].directory, engine: annotated[index].engine
            )
            if let first = firstSlotByAccount[identity] {
                annotated[index].sameAccountAs = first
            } else {
                firstSlotByAccount[identity] = slot
            }
        }
        return annotated
    }

    private func profileDirectories(prefix: String) -> [String] {
        var directories: [String] = []
        let base = (home as NSString).appendingPathComponent(prefix)
        if isDirectory(base) { directories.append(base) }

        let entries = (try? fileManager.contentsOfDirectory(atPath: home)) ?? []
        let alternates = entries
            .filter { $0.hasPrefix(prefix + "-") }
            .map { (home as NSString).appendingPathComponent($0) }
            .filter(isDirectory)
            .sorted()
        directories.append(contentsOf: alternates)
        return directories
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func claudeProfile(directory: String) -> UsageProfile {
        let account = claudeAccount(directory: directory)
        var profile = UsageProfile(
            engine: .claude,
            directory: directory,
            name: URL(fileURLWithPath: directory).lastPathComponent,
            email: account["emailAddress"] as? String,
            organization: account["organizationName"] as? String
        )
        profile.accountKey = account["accountUuid"] as? String
            ?? account["emailAddress"] as? String

        guard var credentials = claudeCredentials(directory: directory) else {
            profile.error = "not logged in"
            return profile
        }
        profile.plan = credentials["subscriptionType"] as? String

        if let expiresAt = number(credentials["expiresAt"]), expiresAt / 1000 < Date().timeIntervalSince1970 {
            // Expiry is renewed in place rather than reported: see refreshOAuth for why an
            // expired non-default token is the one case where that is race-free.
            if !ClaudeSession.isDefault(directory),
               ClaudeSession.refreshOAuth(directory: directory),
               let renewed = claudeCredentials(directory: directory) {
                credentials = renewed
            } else {
                profile.error = "token expired"
                loadCache(into: &profile)
                return profile
            }
        }
        guard var accessToken = credentials["accessToken"] as? String else {
            profile.error = "missing access token"
            return profile
        }

        // The expiry timestamp sometimes claims validity the server no longer honors, so a
        // stale-token rejection gets one renew-and-retry before it is surfaced.
        var attempt = fetchUsage(token: accessToken)
        if case .failure(let error) = attempt, error.description == "token stale",
           !ClaudeSession.isDefault(directory),
           ClaudeSession.refreshOAuth(directory: directory),
           let renewed = claudeCredentials(directory: directory),
           let renewedToken = renewed["accessToken"] as? String {
            accessToken = renewedToken
            attempt = fetchUsage(token: accessToken)
        }

        // The TOKEN decides who this profile is. `.claude.json` only records who logged in
        // last, and any running session rewrites it on refresh - so after an account swap a
        // live session can stamp its own account back onto the default profile's config and
        // the row would name the wrong subscription while showing the right numbers. Observed
        // 2026-08-22. Config stays the offline fallback.
        if let identity = claudeIdentity(token: accessToken) {
            profile.email = identity.email ?? profile.email
            profile.organization = identity.organization ?? profile.organization
            profile.accountKey = identity.uuid ?? identity.email ?? profile.accountKey
        }

        switch attempt {
        case .success(let payload):
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let limits = object["limits"] as? [[String: Any]] else {
                profile.error = "invalid usage response"
                loadCache(into: &profile)
                return profile
            }
            profile.limits = limits.compactMap(parseClaudeLimit)
            saveCache(profile)
        case .failure(let error):
            profile.error = error.description
            loadCache(into: &profile)
        }
        return profile
    }

    private func fetchUsage(token: String) -> Result<Data, RequestError> {
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        return synchronousRequest(request)
    }

    /// Resolves an access token to the account it actually belongs to.
    private func claudeIdentity(
        token: String
    ) -> (email: String?, organization: String?, uuid: String?)? {
        var request = URLRequest(url: profileURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        guard case .success(let payload) = synchronousRequest(request),
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let account = root["account"] as? [String: Any] else { return nil }
        let organization = (root["organization"] as? [String: Any])?["name"] as? String
        return (account["email"] as? String, organization, account["uuid"] as? String)
    }

    private func claudeAccount(directory: String) -> [String: Any] {
        let defaultDirectory = (home as NSString).appendingPathComponent(".claude")
        let path = directory == defaultDirectory
            ? (home as NSString).appendingPathComponent(".claude.json")
            : (directory as NSString).appendingPathComponent(".claude.json")
        guard let object = jsonDictionary(at: path) else { return [:] }
        return object["oauthAccount"] as? [String: Any] ?? [:]
    }

    private func claudeCredentials(directory: String) -> [String: Any]? {
        ClaudeSession.credentials(for: directory)
    }

    private func parseClaudeLimit(_ entry: [String: Any]) -> UsageLimit? {
        guard let kind = entry["kind"] as? String else { return nil }
        let scope = entry["scope"] as? [String: Any]
        let model = scope?["model"] as? [String: Any]
        let modelName = model?["display_name"] as? String

        var label: String
        switch kind {
        case "session": label = "Session (5h)"
        case "weekly_all": label = "Weekly"
        default: label = kind
        }
        if let modelName { label = "Weekly · \(modelName)" }

        let percent = number(entry["percent"])
        let severity = entry["severity"] as? String ?? UsageFormatting.severity(for: percent)
        let resetsAt = (entry["resets_at"] as? String).flatMap(parseISODate)?.timeIntervalSince1970
        return UsageLimit(
            label: label,
            percent: percent,
            severity: severity,
            resetsAt: resetsAt,
            binding: entry["is_active"] as? Bool ?? false
        )
    }

    private func codexProfile(directory: String) -> UsageProfile {
        let account = codexAccount(directory: directory)
        var profile = UsageProfile(
            engine: .codex,
            directory: directory,
            name: URL(fileURLWithPath: directory).lastPathComponent,
            email: account.email,
            plan: account.plan
        )
        profile.accountKey = account.email
        guard account.email != nil else {
            profile.error = "not logged in"
            return profile
        }

        // The app-server RPC is the truth: live percentages, and rateLimitReachedType - the
        // one signal session files never carry, because refused runs write no session at all.
        if let live = codexLiveLimits(directory: directory) {
            applyCodexLimits(live, to: &profile)
            return profile
        }

        // Offline or no CLI: fall back to the newest session file. Its numbers are only as
        // fresh as the last successful run, and it cannot see an enforcement cut-over, so the
        // observedAt age stays visible as the staleness warning.
        for session in newestSessionFiles(directory: directory).prefix(8) {
            if let result = readCodexLimits(path: session.path) {
                applyCodexLimits(result.limits, to: &profile)
                profile.observedAt = result.observedAt
                return profile
            }
        }
        profile.error = "no usage seen yet — run Codex once"
        return profile
    }

    /// Renders one rate_limits payload onto the profile. Handles both spellings - the
    /// app-server speaks camelCase, session files snake_case.
    private func applyCodexLimits(_ limits: [String: Any], to profile: inout UsageProfile) {
        let reached = (limits["rate_limit_reached_type"] ?? limits["rateLimitReachedType"]) as? String
        let blocked = reached?.isEmpty == false
        func field(_ window: [String: Any], _ snake: String, _ camel: String) -> Double? {
            number(window[snake]) ?? number(window[camel])
        }
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            let minutes = Int(field(window, "window_minutes", "windowDurationMins") ?? 0)
            let suffix = minutes >= 1440 ? "\(minutes / 1440)d" : "\(minutes / 60)h"
            let name = minutes >= 1440 * 6 ? "Weekly" : (minutes <= 360 ? "Session" : "Window")
            let percent = field(window, "used_percent", "usedPercent")
            profile.limits.append(UsageLimit(
                label: "\(name) (\(suffix))",
                percent: percent,
                severity: blocked ? "critical" : UsageFormatting.severity(for: percent),
                resetsAt: field(window, "resets_at", "resetsAt")
            ))
        }
        // A full red bar already says "at limit"; the text only appears when the meter alone
        // would not - enforcement engaged while no window reads 100.
        if blocked, !profile.limits.contains(where: { ($0.percent ?? 0) >= 100 }) {
            profile.error = "at limit"
        }
        if let credits = limits["credits"] as? [String: Any],
           let balance = credits["balance"] as? String, balance != "0" {
            profile.note = "Credits available · \(balance)"
        }
    }

    /// Asks a short-lived `codex app-server` for the account's rate limits. This is a local
    /// RPC backed by the stored login - it spends no model tokens. Returns nil when the CLI
    /// is missing or the round-trip fails, so callers can fall back to session files.
    private func codexLiveLimits(directory: String) -> [String: Any]? {
        guard let binary = codexExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        let responseReady = DispatchSemaphore(value: 0)
        let bufferLock = NSLock()
        var buffer = Data()
        var response: [String: Any]?
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferLock.lock()
            buffer.append(chunk)
            let lines = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2,
                      let result = object["result"] as? [String: Any],
                      let limits = result["rateLimits"] as? [String: Any] else { continue }
                response = limits
            }
            bufferLock.unlock()
            if response != nil { responseReady.signal() }
        }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"overseer","title":"Overseer","version":"\(version)"}}}
        {"jsonrpc":"2.0","method":"initialized"}
        {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}

        """
        input.fileHandleForWriting.write(Data(requests.utf8))
        _ = responseReady.wait(timeout: .now() + 15)
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return response
    }

    /// Grok Build (xAI's coding CLI) exposes no usage endpoint anywhere - not on api.x.ai,
    /// not on cli-chat-proxy.grok.com, not on its stdio agent (verified 2026-08-18; the TUI's
    /// /usage screen arrives over its private websocket). So the row is identity plus the
    /// outcome of the newest session: enough to see the sub is mounted and whether the last
    /// run was refused for quota.
    private func grokProfile(directory: String) -> UsageProfile {
        var profile = UsageProfile(
            engine: .grok,
            directory: directory,
            name: URL(fileURLWithPath: directory).lastPathComponent
        )
        guard let account = grokAccount(directory: directory) else {
            profile.error = "not logged in"
            return profile
        }
        profile.email = account.email
        profile.plan = account.plan
        profile.accountKey = account.userId ?? account.email

        let run = grokLastRun(directory: directory)
        profile.observedAt = run.observedAt
        if run.blocked {
            profile.error = "at limit - the last run was refused"
        }
        return profile
    }

    private func grokAccount(directory: String) -> (email: String?, plan: String?, userId: String?)? {
        let path = (directory as NSString).appendingPathComponent("auth.json")
        guard let root = jsonDictionary(at: path),
              let entry = root.values.first(where: { $0 is [String: Any] }) as? [String: Any] else {
            return nil
        }
        var plan: String?
        if let token = entry["key"] as? String {
            let parts = token.split(separator: ".")
            if parts.count > 1 {
                var payload = String(parts[1])
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
                if let data = Data(base64Encoded: payload),
                   let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tier = number(claims["tier"]) {
                    // Empirical: an X Premium+ account reports tier 4. Other tiers
                    // show their raw number until observed.
                    plan = Int(tier) == 4 ? "premium+" : "tier \(Int(tier))"
                }
            }
        }
        return (entry["email"] as? String, plan, entry["user_id"] as? String)
    }

    /// Newest session outcome: when it ran, and whether it ended refused for quota. Grok
    /// sessions live at sessions/<escaped-cwd>/<session-id>/events.jsonl.
    private func grokLastRun(directory: String) -> (observedAt: TimeInterval?, blocked: Bool) {
        let root = URL(fileURLWithPath: directory).appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (nil, false) }

        var newest: (path: String, date: Date)?
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "events.jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest!.date {
                newest = (url.path, date)
            }
        }
        guard let newest else { return (nil, false) }

        var blocked = false
        if let handle = FileHandle(forReadingAtPath: newest.path) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd() {
                try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                if let data = try? handle.readToEnd(),
                   let text = String(data: data, encoding: .utf8) {
                    blocked = text.contains("usage_pool_exhausted")
                        || text.contains("usage_limit_reached")
                }
            }
        }
        return (newest.date.timeIntervalSince1970, blocked)
    }

    /// Where the Codex CLI lives; a GUI app inherits no PATH. pnpm's global shim is a
    /// common install location, checked first.
    private func codexExecutable() -> String? {
        let candidates = [
            "\(home)/Library/pnpm/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    private func codexAccount(directory: String) -> (email: String?, plan: String?) {
        let path = (directory as NSString).appendingPathComponent("auth.json")
        guard let root = jsonDictionary(at: path),
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String else { return (nil, nil) }
        let components = token.split(separator: ".")
        guard components.count > 1 else { return (nil, nil) }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return (claims["email"] as? String, auth?["chatgpt_plan_type"] as? String)
    }

    private func newestSessionFiles(directory: String) -> [(path: String, date: Date)] {
        let root = URL(fileURLWithPath: directory).appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(String, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files.append((url.path, values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }
    }

    private func readCodexLimits(path: String) -> (limits: [String: Any], observedAt: TimeInterval?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            if size > 512_000 {
                try handle.seek(toOffset: size - 512_000)
            } else {
                try handle.seek(toOffset: 0)
            }
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let lineData = String(line).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any] else { continue }
                let observed = (event["timestamp"] as? String).flatMap(parseISODate)?.timeIntervalSince1970
                return (limits, observed)
            }
        } catch { }
        return nil
    }

    private func synchronousRequest(_ request: URLRequest) -> Result<Data, RequestError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, RequestError> = .failure(.message("network timeout"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(.message(error.localizedDescription))
                return
            }
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                let message = response.statusCode == 401 ? "token stale" : "HTTP \(response.statusCode)"
                result = .failure(.message(message))
                return
            }
            result = data.map(Result.success) ?? .failure(.message("empty response"))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 20) == .timedOut { task.cancel() }
        return result
    }

    private func jsonDictionary(at path: String) -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func parseISODate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private var cacheDirectory: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Overseer", isDirectory: true).appendingPathComponent("Cache", isDirectory: true)
    }

    private func cacheURL(for directory: String) -> URL {
        let digest = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(String(digest.prefix(12)) + ".json")
    }

    private func saveCache(_ profile: UsageProfile) {
        guard !profile.limits.isEmpty else { return }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = CachedLimits(savedAt: Date().timeIntervalSince1970, limits: profile.limits)
        if let data = try? JSONEncoder().encode(cached) {
            try? data.write(to: cacheURL(for: profile.directory), options: .atomic)
        }
    }

    private func loadCache(into profile: inout UsageProfile) {
        guard let data = try? Data(contentsOf: cacheURL(for: profile.directory)),
              let cached = try? JSONDecoder().decode(CachedLimits.self, from: data) else { return }
        profile.limits = cached.limits
        profile.observedAt = cached.savedAt
    }
}
