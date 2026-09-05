import AppKit
import CryptoKit
import Foundation

/// Re-authenticating a Claude profile without leaving the app.
///
/// Access tokens last about twelve hours, so a subscription you rarely drive is usually expired
/// when you look at it. The stored refresh token is normally still good, and any Claude Code run
/// against that profile renews it - including one that immediately hits a usage limit. So the
/// common case is a silent one-word run, and only a genuinely logged-out profile needs the
/// interactive login.
enum ClaudeSession {
    /// The default profile must be driven with CLAUDE_CONFIG_DIR *unset*. Setting it - even to
    /// the default path itself - moves the CLI onto a hash-suffixed Keychain item and an
    /// in-directory config file, forking the profile's identity from what every plain
    /// `claude` invocation uses — an easy state to hit by accident.
    static func isDefault(_ directory: String) -> Bool {
        let defaultDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return URL(fileURLWithPath: directory).standardized.path
            == URL(fileURLWithPath: defaultDirectory).standardized.path
    }

    static func keychainService(for directory: String) -> String {
        if isDefault(directory) {
            return "Claude Code-credentials"
        }
        let digest = SHA256.hash(data: Data(directory.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "Claude Code-credentials-\(digest.prefix(8))"
    }

    private static func environment(for directory: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if isDefault(directory) {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = directory
        }
        return environment
    }

    static func credentials(for directory: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: directory), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return root["claudeAiOauth"] as? [String: Any]
                }
            }
        } catch { }

        let fallback = (directory as NSString).appendingPathComponent(".credentials.json")
        guard let data = FileManager.default.contents(atPath: fallback),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["claudeAiOauth"] as? [String: Any]
    }

    /// Seconds since 1970 when the current access token stops working.
    static func expiry(for directory: String) -> TimeInterval? {
        guard let value = credentials(for: directory)?["expiresAt"] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue / 1000 }
        if let string = value as? String, let number = Double(string) { return number / 1000 }
        return nil
    }

    /// A stored credential means the refresh token is worth trying; no credential means login.
    static func canRenewSilently(directory: String) -> Bool {
        credentials(for: directory) != nil
    }

    private static var defaultDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    /// The full Keychain secret exactly as Claude Code stored it, for moving a login between
    /// profiles without another browser round-trip.
    private static func rawSecret(for directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService(for: directory), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let secret = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .newlines)
        return (secret?.isEmpty == false) ? secret : nil
    }

    @discardableResult
    private static func writeSecret(_ secret: String, for directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "add-generic-password", "-U",
            "-a", NSUserName(),
            "-s", keychainService(for: directory),
            "-w", secret,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func deleteSecret(for directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", keychainService(for: directory)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// The keys in `.claude.json` that say WHICH account is mounted, as opposed to machine-local
    /// state like project history. They travel with the login whenever accounts move between
    /// profiles, so the config's claimed identity never diverges from the Keychain's actual one.
    private static let identityKeys = ["oauthAccount", "userID", "hasAvailableSubscription"]

    private static func configPath(for directory: String) -> String {
        isDefault(directory)
            ? (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
            : (directory as NSString).appendingPathComponent(".claude.json")
    }

    private static func readConfig(_ directory: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: configPath(for: directory)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return root
    }

    private static func writeConfig(_ config: [String: Any], directory: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath(for: directory)), options: .atomic)
    }

    private static func swapIdentity(_ a: String, _ b: String) {
        var configA = readConfig(a)
        var configB = readConfig(b)
        for key in identityKeys {
            let valueA = configA[key]
            configA[key] = configB[key]
            configB[key] = valueA
        }
        writeConfig(configA, directory: a)
        writeConfig(configB, directory: b)
    }

    private static func copyIdentity(from source: String, to destination: String) {
        let sourceConfig = readConfig(source)
        var destinationConfig = readConfig(destination)
        for key in identityKeys {
            destinationConfig[key] = sourceConfig[key]
        }
        writeConfig(destinationConfig, directory: destination)
    }

    /// Makes a slot's account the active one by exchanging logins with the default profile.
    /// Purely local - the Keychain items and config identities move crosswise, no browser
    /// involved - so the previously active account survives, parked on the slot. Returns false
    /// with nothing changed when the slot holds no login or the first Keychain write fails.
    static func swapWithDefault(directory: String) -> Bool {
        guard !isDefault(directory) else { return false }
        guard let slotSecret = rawSecret(for: directory) else { return false }
        let outgoingSecret = rawSecret(for: defaultDirectory)

        guard writeSecret(slotSecret, for: defaultDirectory) else { return false }
        if let outgoingSecret {
            guard writeSecret(outgoingSecret, for: directory) else {
                writeSecret(outgoingSecret, for: defaultDirectory)
                return false
            }
        } else {
            deleteSecret(for: directory)
        }
        swapIdentity(defaultDirectory, directory)
        return true
    }

    /// A profile directory holds two unrelated things: the login, and all the user config that
    /// shapes how Claude behaves - skills, CLAUDE.md, settings, plugins. Only the login is
    /// per-account, but CLAUDE_CONFIG_DIR moves the whole directory, so a fresh slot runs
    /// blind: no skills, none of the user's global rules. Claude Code offers no way to point
    /// several profiles at one config, so new slots get symlinks back to the default
    /// profile's copies. Concurrent access is already normal - several sessions share the
    /// default profile all day - so sharing costs nothing.
    static let sharedConfigItems = [
        "skills", "CLAUDE.md", "settings.json", "settings.local.json",
        "plugins", "agents", "commands",
    ]

    @discardableResult
    static func shareUserConfig(into directory: String) -> Int {
        guard !isDefault(directory) else { return 0 }
        var linked = 0
        for item in sharedConfigItems {
            let source = (defaultDirectory as NSString).appendingPathComponent(item)
            let destination = (directory as NSString).appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: source),
                  !FileManager.default.fileExists(atPath: destination) else { continue }
            do {
                try FileManager.default.createSymbolicLink(
                    atPath: destination, withDestinationPath: source
                )
                linked += 1
            } catch { }
        }
        return linked
    }

    /// Copies the default profile's login onto a slot before the default is re-authenticated in
    /// the browser, so the outgoing account is parked rather than destroyed by the new login.
    @discardableResult
    static func parkDefault(on directory: String) -> Bool {
        guard !isDefault(directory), let secret = rawSecret(for: defaultDirectory) else {
            return false
        }
        guard writeSecret(secret, for: directory) else { return false }
        copyIdentity(from: defaultDirectory, to: directory)
        return true
    }

    /// Where Claude Code lives. A GUI app inherits no PATH, and `zsh -lc` does not source
    /// `.zshrc`, so the usual install locations are checked before falling back to an
    /// interactive login shell.
    static func executable() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let path = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs a throwaway prompt so Claude Code renews the token. Blocking; call off the main thread.
    /// Returns true when the stored expiry has moved into the future.
    @discardableResult
    static func renew(directory: String) -> Bool {
        guard let binary = executable() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "Reply with exactly: OK", "--model", "haiku"]
        process.environment = environment(for: directory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()

        guard let expiry = expiry(for: directory) else { return false }
        return expiry > Date().timeIntervalSince1970
    }

    /// Renews an expired login directly against the OAuth token endpoint - the same refresh
    /// grant the CLI performs, written back in the CLI's exact credential shape, so no model
    /// call, no quota, no browser. Callers must gate on the token being EXPIRED and the
    /// profile being non-default: a live session keeps its own token fresh and rotates the
    /// refresh token when it does, and two writers rotating one refresh token invalidate each
    /// other ("token disconnected"). An expired worker token is itself proof no live session
    /// owns the profile; the default profile always risks an idle session holding the token.
    static func refreshOAuth(directory: String) -> Bool {
        guard let raw = rawSecret(for: directory),
              var root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String else { return false }

        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-cli/2.1.247 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any]?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode), let data else { return }
            payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)

        guard let payload, let accessToken = payload["access_token"] as? String else {
            return false
        }
        oauth["accessToken"] = accessToken
        if let rotated = payload["refresh_token"] as? String {
            oauth["refreshToken"] = rotated
        }
        let lifetime = (payload["expires_in"] as? NSNumber)?.doubleValue ?? 8 * 3600
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + lifetime) * 1000)
        root["claudeAiOauth"] = oauth
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let secret = String(data: data, encoding: .utf8) else { return false }
        return writeSecret(secret, for: directory)
    }

    /// Removes a non-default profile: the directory goes to the Trash (recoverable) and the
    /// profile's Keychain item is deleted. The default profile is never removable - it is what
    /// plain `claude` and Conductor run on.
    @discardableResult
    static func removeProfile(directory: String) -> Bool {
        guard !isDefault(directory) else { return false }
        let delete = Process()
        delete.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        delete.arguments = ["delete-generic-password", "-s", keychainService(for: directory)]
        delete.standardOutput = Pipe()
        delete.standardError = Pipe()
        try? delete.run()
        delete.waitUntilExit()
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: directory), resultingItemURL: nil
            )
            return true
        } catch {
            return false
        }
    }

    /// The account a profile's config claims, freshly read.
    static func accountEmail(directory: String) -> String? {
        let path = isDefault(directory)
            ? (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
            : (directory as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    enum LoginResult {
        case success(email: String?)
        /// The browser's existing claude.ai session signed in as someone else: --email is only
        /// a hint, and an already-authenticated browser clicks straight through it.
        case wrongAccount(requested: String, actual: String)
        case failure
    }

    /// Signs a profile into an account without opening Terminal: `claude auth login` only needs
    /// to open the browser and wait for the localhost callback, so it runs fine headless. Falls
    /// back to a visible Terminal when the process fails or the browser round-trip never lands.
    /// Blocking up to `timeout`; call off the main thread.
    static func loginVerified(
        directory: String, email: String?, timeout: TimeInterval = 240
    ) -> LoginResult {
        guard login(directory: directory, email: email, timeout: timeout) else { return .failure }
        let actual = accountEmail(directory: directory)
        if let requested = email, !requested.isEmpty,
           let actual, actual.lowercased() != requested.lowercased() {
            return .wrongAccount(requested: requested, actual: actual)
        }
        return .success(email: actual)
    }

    @discardableResult
    static func login(directory: String, email: String?, timeout: TimeInterval = 240) -> Bool {
        guard let binary = executable() else {
            openTerminalLogin(directory: directory, email: email)
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["auth", "login"]
        if let email, !email.isEmpty {
            arguments += ["--email", email]
        }
        process.arguments = arguments
        process.environment = environment(for: directory)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            openTerminalLogin(directory: directory, email: email)
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        if process.isRunning {
            process.terminate()
            openTerminalLogin(directory: directory, email: email)
            return false
        }
        return process.terminationStatus == 0
    }

    /// Opens Terminal on the interactive login for exactly this profile, pre-filling the account
    /// so the browser lands on the right sign-in rather than whichever session the browser holds.
    ///
    /// Terminal executes a `.command` file directly, so this needs no Apple Events entitlement.
    /// Scripting Terminal instead requires NSAppleEventsUsageDescription and user consent, and
    /// when that is missing the `activate` succeeds while `do script` is silently refused -
    /// Terminal comes forward showing an empty window.
    static func openTerminalLogin(directory: String, email: String?) {
        let binary = executable() ?? "claude"
        let prefix = isDefault(directory) ? "" : "CLAUDE_CONFIG_DIR=\(shellQuoted(directory)) "
        var command = "\(prefix)\(shellQuoted(binary)) auth login"
        if let email, !email.isEmpty {
            command += " --email \(shellQuoted(email))"
        }
        let profileName = URL(fileURLWithPath: directory).lastPathComponent
        let script = """
        #!/bin/zsh
        clear
        echo "Overseer · signing \(profileName) into a Claude account"
        echo
        \(command)
        exit_code=$?
        echo
        if [ $exit_code -eq 0 ]; then
            echo "Done - closing this window."
            this_tty=$(tty)
            osascript -e "tell application \\"Terminal\\" to close (every window whose tty of selected tab is \\"$this_tty\\")" >/dev/null 2>&1 &
        else
            echo "Login did not complete (exit $exit_code). This window stays open so you can read why."
        fi
        """
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Overseer", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("login-\(profileName).command")
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path
        )
        NSWorkspace.shared.open(file)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
