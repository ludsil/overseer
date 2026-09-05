import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let collector = UsageCollector()
    private var timer: Timer?
    private var profiles: [UsageProfile] = []
    private var updatedAt: Date?
    private var isRefreshing = false
    private var reconnecting: Set<String> = []
    private var signingIn: Set<String> = []
    private var switching: Set<String> = []
    private var loginNotice: String?
    private lazy var windowController = OverseerWindowController(
        build: { [unowned self] in self.makeContentController() },
        diagnostics: { [unowned self] in
            StatusItemDiagnostics.report(for: self.statusItem, profiles: self.profiles.count)
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureStatusItem()
        configurePopover()
        refresh()
        if ProcessInfo.processInfo.arguments.contains("--diagnose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                print(StatusItemDiagnostics.report(for: self.statusItem, profiles: self.profiles.count))
                NSApp.terminate(nil)
            }
            return
        }
        showWindowOnFirstLaunch()
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePopover()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Reopening from Finder is what a user tries when the menu bar icon is missing; without this
    /// it silently does nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.show(explainMenuBar: StatusItemDiagnostics.isSuspicious(statusItem))
        return false
    }

    private func showWindowOnFirstLaunch() {
        let key = "OverseerHasLaunchedBefore"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.windowController.show(explainMenuBar: true)
        }
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "OverseerPrimaryStatusItem"
        guard let button = statusItem.button else { return }
        if let path = Bundle.main.path(forResource: "overseer-menu@2x", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Overseer")
        }
        button.imagePosition = .imageOnly
        button.toolTip = "Overseer · loading usage"
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = NSAppearance(named: .darkAqua)
        updatePopoverContent()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        updatePopoverContent()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        updatePopoverContent()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let profiles = self.collector.discover()
            DispatchQueue.main.async {
                self.profiles = profiles
                self.updatedAt = Date()
                self.isRefreshing = false
                self.apply(profiles)
            }
        }
    }

    private func apply(_ profiles: [UsageProfile]) {
        let values = profiles.map { profile -> String in
            let percent = profile.limits.compactMap(\.percent).max()
            return percent.map { String(Int($0)) } ?? "—"
        }
        statusItem.button?.toolTip = "Overseer · " + values.joined(separator: "·")
        updatePopoverContent()
    }

    private func updatePopoverContent() {
        popover.contentViewController = makeContentController()
        windowController.refreshIfVisible()
    }

    private func makeContentController() -> NSViewController {
        let controller = NSViewController()
        let root = NSVisualEffectView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.isEmphasized = true

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 7
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outerStack)

        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 420),
            outerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            outerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            outerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            outerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        let profileStack = FlippedStackView()
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 6
        profileStack.frame = NSRect(x: 0, y: 0, width: 388, height: 1)

        if profiles.isEmpty {
            let message = isRefreshing ? "Refreshing usage…" : "No local profiles found"
            let label = textLabel(
                message,
                font: .systemFont(ofSize: 13, weight: .regular),
                color: UsageFormatting.secondaryText
            )
            addFullWidth(label, to: profileStack, height: 20)
        } else {
            for (index, profile) in profiles.enumerated() {
                if index > 0 { addSeparator(to: profileStack) }
                addProfile(profile, to: profileStack)
            }
        }

        addProfileRegion(profileStack, to: outerStack)
        if let loginNotice {
            let notice = textLabel(
                loginNotice,
                font: .systemFont(ofSize: 11, weight: .medium),
                color: UsageFormatting.color(for: "warning")
            )
            notice.maximumNumberOfLines = 3
            notice.lineBreakMode = .byWordWrapping
            notice.preferredMaxLayoutWidth = 388
            addFullWidth(notice, to: outerStack, height: 42)
        }
        addSeparator(to: outerStack)
        addFullWidth(statusAndRefreshRow(), to: outerStack, height: 25)

        if #available(macOS 13.0, *) {
            addFullWidth(launchAtLoginRow(), to: outerStack, height: 25)
        }

        addSeparator(to: outerStack)
        let manageButton = actionButton(
            "Manage Claude accounts",
            symbol: "person.2",
            action: #selector(manageAccounts(_:)),
            keyEquivalent: ""
        )
        addFullWidth(manageButton, to: outerStack, height: 25)

        let quitButton = actionButton(
            "Quit Overseer",
            symbol: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        addFullWidth(quitButton, to: outerStack, height: 25)

        controller.view = root
        controller.preferredContentSize = NSSize(
            width: 420,
            height: max(72, outerStack.fittingSize.height + 25)
        )
        return controller
    }

    private func addProfile(_ profile: UsageProfile, to stack: NSStackView) {
        addFullWidth(profileHeader(profile), to: stack, height: 19)
        stack.setCustomSpacing(7, after: stack.arrangedSubviews.last!)

        // Auth problems ride along in the header next to the account they belong to; anything
        // else still gets its own line.
        if let error = profile.error, !isAuthError(error) {
            let errorLabel = textLabel(
                error,
                font: .systemFont(ofSize: 11.5, weight: .medium),
                color: UsageFormatting.color(for: "critical")
            )
            addFullWidth(errorLabel, to: stack, height: 14)
        }

        let weeklyExhausted = profile.limits.contains {
            $0.label == "Weekly" && ($0.percent ?? 0) >= 100
        }
        for limit in profile.limits {
            let inheritedSeverity = weeklyExhausted && limit.label == "Session (5h)"
                ? "critical"
                : nil
            let row = usageRow(limit, severityOverride: inheritedSeverity)
            addFullWidth(row.view, to: stack, height: row.height)
        }

        if let note = profile.note {
            let noteLabel = textLabel(
                note,
                font: .systemFont(ofSize: 11, weight: .regular),
                color: UsageFormatting.secondaryText
            )
            addFullWidth(noteLabel, to: stack, height: 14)
        }

        if let age = UsageFormatting.ageDescription(profile.observedAt) {
            let note: String
            switch profile.engine {
            case .claude: note = "Cached"
            case .codex: note = "Last Codex run"
            case .grok: note = "Last Grok run"
            }
            let ageLabel = textLabel(
                "\(note) · \(age)",
                font: .systemFont(ofSize: 11, weight: .regular),
                color: UsageFormatting.secondaryText
            )
            addFullWidth(ageLabel, to: stack, height: 14)
        }
    }

    private func isAuthError(_ error: String) -> Bool {
        ["token expired", "not logged in", "missing access token"].contains(error)
    }

    /// One click back to a working profile: renew silently when a credential is still stored,
    /// otherwise hand over to the interactive login for that exact account.
    private func reconnectControl(for profile: UsageProfile) -> NSView {
        if reconnecting.contains(profile.directory) {
            return textLabel(
                "Reconnecting…",
                font: .systemFont(ofSize: 11, weight: .medium),
                color: UsageFormatting.secondaryText
            )
        }
        let silent = ClaudeSession.canRenewSilently(directory: profile.directory)
        let button = NSButton(
            title: silent ? "Reconnect" : "Mount account…",
            target: self,
            action: #selector(reconnect(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.identifier = NSUserInterfaceItemIdentifier(profile.directory)
        button.toolTip = silent
            ? "Renew this account's token"
            : "Open the Claude login for \(profile.email ?? profile.name)"
        return button
    }

    /// The active account is whatever the default profile holds - it is what plain `claude`,
    /// Conductor, and every tool without CLAUDE_CONFIG_DIR uses.
    private func isActive(_ profile: UsageProfile) -> Bool {
        ClaudeSession.isDefault(profile.directory)
    }

    private func activeBadge() -> NSView {
        let badge = textLabel(
            "ACTIVE",
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: UsageFormatting.color(for: "normal")
        )
        badge.toolTip = "This account is signed into the default profile - what plain claude, "
            + "Conductor, and other tools use. Use Make active on another row to switch globally."
        return badge
    }

    /// Making an account active swaps logins with the default profile: this slot's stored
    /// credential moves onto what plain `claude` and Conductor use, and the outgoing account
    /// parks on this slot - nothing is lost and no browser is involved. Only a slot with no
    /// stored login falls back to the browser flow, and even then the outgoing login is parked
    /// on the slot first.
    private func switchAccountControl(for profile: UsageProfile) -> NSView {
        let button = NSButton(
            title: "Make active",
            target: self,
            action: #selector(makeActive(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.identifier = NSUserInterfaceItemIdentifier(profile.directory)
        button.toolTip = "Make \(profile.email ?? "this account") the one Conductor and plain "
            + "claude use. Sessions already running keep the account they started on."
        return button
    }

    @objc private func makeActive(_ sender: NSButton) {
        guard let directory = sender.identifier?.rawValue, !directory.isEmpty else { return }
        if ClaudeSession.canRenewSilently(directory: directory) {
            beginSwap(directory: directory)
            return
        }
        // No stored login to swap in, so the browser has to mint one for the default profile.
        // Park the outgoing active login on this slot first so it survives the switch.
        let email = profiles.first { $0.directory == directory }?.email
        ClaudeSession.parkDefault(on: directory)
        let defaultDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        beginLogin(directory: defaultDirectory, email: email)
    }

    private func beginSwap(directory: String) {
        switching.insert(directory)
        loginNotice = nil
        updatePopoverContent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let swapped = ClaudeSession.swapWithDefault(directory: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.switching.remove(directory)
                if swapped {
                    self.applySwapLocally(directory: directory)
                } else {
                    self.loginNotice = "Could not swap accounts - the Keychain move failed "
                        + "and nothing was changed."
                }
                self.refresh()
            }
        }
    }

    private func beginLogin(directory: String, email: String?) {
        signingIn.insert(directory)
        loginNotice = nil
        updatePopoverContent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ClaudeSession.loginVerified(directory: directory, email: email)
            DispatchQueue.main.async {
                guard let self else { return }
                self.signingIn.remove(directory)
                switch result {
                case .success:
                    break
                case .wrongAccount(let requested, let actual):
                    self.loginNotice = "Browser signed in as \(actual), not \(requested). "
                        + "Your browser's live claude.ai session decided - retry from a private "
                        + "window, or switch accounts on claude.ai first."
                case .failure:
                    self.loginNotice = "Login did not complete."
                }
                self.refresh()
            }
        }
    }

    /// The swap already moved the credentials, so the new arrangement is known without asking
    /// the network: exchange the two rows' account fields right away. A full refresh still
    /// follows, but the popover stops showing the old account - and the switch stops looking
    /// like it did nothing - while six HTTP round trips run.
    private func applySwapLocally(directory: String) {
        let defaultDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        guard let here = profiles.firstIndex(where: { $0.directory == defaultDirectory }),
              let there = profiles.firstIndex(where: { $0.directory == directory }) else { return }
        var defaultRow = profiles[here]
        var slotRow = profiles[there]
        let outgoing = (
            defaultRow.email, defaultRow.organization, defaultRow.plan,
            defaultRow.accountKey, defaultRow.limits, defaultRow.error
        )
        defaultRow.email = slotRow.email
        defaultRow.organization = slotRow.organization
        defaultRow.plan = slotRow.plan
        defaultRow.accountKey = slotRow.accountKey
        defaultRow.limits = slotRow.limits
        defaultRow.error = slotRow.error
        (slotRow.email, slotRow.organization, slotRow.plan,
         slotRow.accountKey, slotRow.limits, slotRow.error) = outgoing
        profiles[here] = defaultRow
        profiles[there] = slotRow
        updatePopoverContent()
    }

    @objc private func manageAccounts(_ sender: NSButton) {
        let menu = NSMenu()
        let add = NSMenuItem(
            title: "Add account…", action: #selector(addAccount), keyEquivalent: ""
        )
        add.target = self
        add.toolTip = "Opens the Claude login and adds that account to this list"
        menu.addItem(add)

        for profile in profiles where profile.engine == .claude {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: profile.email ?? "No account", action: nil, keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)

            let mount = NSMenuItem(
                title: "Replace with another account…",
                action: #selector(mountDifferent(_:)),
                keyEquivalent: ""
            )
            mount.target = self
            mount.representedObject = profile.directory
            menu.addItem(mount)

            if !ClaudeSession.isDefault(profile.directory) {
                let remove = NSMenuItem(
                    title: "Remove…", action: #selector(removeProfile(_:)), keyEquivalent: ""
                )
                remove.target = self
                remove.representedObject = profile.directory
                menu.addItem(remove)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func mountDifferent(_ item: NSMenuItem) {
        guard let directory = item.representedObject as? String else { return }
        popover.performClose(nil)
        beginLogin(directory: directory, email: nil)
    }

    @objc private func removeProfile(_ item: NSMenuItem) {
        guard let directory = item.representedObject as? String else { return }
        popover.performClose(nil)
        let alert = NSAlert()
        let name = profiles.first { $0.directory == directory }?.email ?? "this account"
        alert.messageText = "Remove \(name)?"
        alert.informativeText = "Its saved login is deleted from this Mac. The Claude account "
            + "itself is not affected - you can add it back by signing in again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !ClaudeSession.removeProfile(directory: directory) {
            loginNotice = "Could not remove \(name)."
        }
        refresh()
    }

    /// Adding an account is just the login: it needs a config directory to live in, so one is
    /// created behind the scenes and never shown - the account's own name is the identity.
    @objc private func addAccount() {
        popover.performClose(nil)
        let home = NSHomeDirectory()
        var index = 2
        var directory = "\(home)/.claude-\(index)"
        while FileManager.default.fileExists(atPath: directory) {
            index += 1
            directory = "\(home)/.claude-\(index)"
        }
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        ClaudeSession.shareUserConfig(into: directory)
        beginLogin(directory: directory, email: nil)
    }

    @objc private func reconnect(_ sender: NSButton) {
        guard let directory = sender.identifier?.rawValue else { return }
        let email = profiles.first { $0.directory == directory }?.email
        guard ClaudeSession.canRenewSilently(directory: directory) else {
            beginLogin(directory: directory, email: email)
            return
        }
        reconnecting.insert(directory)
        updatePopoverContent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The OAuth refresh is instant and free; the throwaway `claude -p` run stays as
            // the fallback and as the default profile's only path (see refreshOAuth).
            let renewed = (!ClaudeSession.isDefault(directory)
                    && ClaudeSession.refreshOAuth(directory: directory))
                || ClaudeSession.renew(directory: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reconnecting.remove(directory)
                if renewed {
                    self.refresh()
                } else {
                    self.beginLogin(directory: directory, email: email)
                }
            }
        }
    }

    private func profileHeader(_ profile: UsageProfile) -> NSView {
        let engine: String
        switch profile.engine {
        case .claude: engine = "Claude"
        case .codex: engine = "Codex"
        case .grok: engine = "Grok"
        }
        // An account is named by its own address, not by the folder it happens to live in.
        // Codex and Grok lead with the engine instead, since one account each makes the
        // engine the distinguishing fact - and the address still follows it.
        let leading = profile.engine == .claude
            ? (profile.email ?? "No account")
            : SlotNames.name(for: profile.directory, engine: profile.engine)
        let trailing = profile.engine == .claude ? nil : profile.email

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7

        let engineLabel = textLabel(
            leading,
            font: .systemFont(ofSize: 12.5, weight: .semibold),
            color: UsageFormatting.providerColor(for: profile.engine)
        )
        engineLabel.toolTip = "\(engine) · \(profile.directory)"
        row.addArrangedSubview(engineLabel)

        if let trailing {
            row.addArrangedSubview(textLabel(
                "·",
                font: .systemFont(ofSize: 11, weight: .regular),
                color: UsageFormatting.tertiaryText
            ))
            row.addArrangedSubview(textLabel(
                trailing,
                font: .systemFont(ofSize: 11.5, weight: .regular),
                color: UsageFormatting.secondaryText
            ))
        }

        // Two entries on one account: the repeated address says it, the tag says why it matters.
        if profile.sameAccountAs != nil {
            row.addArrangedSubview(textLabel(
                "·",
                font: .systemFont(ofSize: 11, weight: .regular),
                color: UsageFormatting.tertiaryText
            ))
            let label = textLabel(
                "duplicate",
                font: .systemFont(ofSize: 11.5, weight: .regular),
                color: UsageFormatting.tertiaryText
            )
            label.toolTip = "The same account is listed twice, so it adds no extra quota - and "
                + "two copies of one login invalidate each other's token. Replace or remove one."
            row.addArrangedSubview(label)
        }

        if let error = profile.error, isAuthError(error) {
            row.addArrangedSubview(textLabel(
                "·",
                font: .systemFont(ofSize: 11, weight: .regular),
                color: UsageFormatting.tertiaryText
            ))
            row.addArrangedSubview(textLabel(
                error,
                font: .systemFont(ofSize: 11.5, weight: .regular),
                color: UsageFormatting.color(for: "critical")
            ))
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        if profile.engine == .claude, let error = profile.error, isAuthError(error) {
            row.addArrangedSubview(reconnectControl(for: profile))
        } else {
            if let plan = profile.plan, !plan.isEmpty {
                let planLabel = textLabel(
                    plan.uppercased(),
                    font: .systemFont(ofSize: 9.5, weight: .semibold),
                    color: UsageFormatting.secondaryText
                )
                row.addArrangedSubview(planLabel)
            }
            if profile.engine == .claude {
                if isActive(profile) {
                    row.addArrangedSubview(activeBadge())
                } else if switching.contains(profile.directory) {
                    row.addArrangedSubview(textLabel(
                        "Switching…",
                        font: .systemFont(ofSize: 11, weight: .medium),
                        color: UsageFormatting.secondaryText
                    ))
                } else if signingIn.contains(profile.directory) {
                    row.addArrangedSubview(textLabel(
                        "Signing in…",
                        font: .systemFont(ofSize: 11, weight: .medium),
                        color: UsageFormatting.secondaryText
                    ))
                } else if profile.sameAccountAs == nil {
                    row.addArrangedSubview(switchAccountControl(for: profile))
                }
            }
        }
        return row
    }

    private func usageRow(
        _ limit: UsageLimit,
        severityOverride: String? = nil
    ) -> (view: NSView, height: CGFloat) {
        let row = NSView()
        let color = UsageFormatting.color(for: severityOverride ?? limit.severity)

        let title = textLabel(
            limit.label,
            font: .systemFont(ofSize: 11.5, weight: .medium),
            color: UsageFormatting.primaryText
        )
        title.toolTip = limit.label
        let percentage = limit.percent.map { String(format: "%.0f%%", $0) } ?? "—"
        let percentageLabel = textLabel(
            percentage,
            font: .monospacedSystemFont(ofSize: 11.5, weight: .semibold),
            color: color
        )
        percentageLabel.alignment = .right
        let resetLabel = textLabel(
            UsageFormatting.resetDescription(limit.resetsAt) ?? "—",
            font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
            color: UsageFormatting.secondaryText
        )
        resetLabel.alignment = .right
        let bar = UsageBarView(percent: limit.percent, color: color)

        for view in [title, percentageLabel, resetLabel, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -10),
            bar.widthAnchor.constraint(equalToConstant: 56),
            bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 3),
            percentageLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 6),
            percentageLabel.widthAnchor.constraint(equalToConstant: 42),
            percentageLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            resetLabel.leadingAnchor.constraint(equalTo: percentageLabel.trailingAnchor, constant: 10),
            resetLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            resetLabel.widthAnchor.constraint(equalToConstant: 86),
            resetLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        return (row, 18)
    }

    private func addProfileRegion(_ profileStack: FlippedStackView, to outerStack: NSStackView) {
        profileStack.layoutSubtreeIfNeeded()
        let contentHeight = ceil(profileStack.fittingSize.height)
        let visibleHeight = min(contentHeight, 430)

        if contentHeight <= 430 {
            addFullWidth(profileStack, to: outerStack, height: visibleHeight)
            return
        }

        profileStack.frame = NSRect(x: 0, y: 0, width: 388, height: contentHeight)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = profileStack
        addFullWidth(scrollView, to: outerStack, height: visibleHeight)
    }

    private func statusAndRefreshRow() -> NSView {
        let refreshButton = actionButton(
            isRefreshing ? "Refreshing…" : "Refresh",
            symbol: "arrow.clockwise",
            action: #selector(refresh),
            keyEquivalent: "r"
        )
        refreshButton.isEnabled = !isRefreshing

        let updated = updatedAt.map {
            DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
        } ?? "—"
        let updatedLabel = PassthroughTextField(labelWithString: "Updated \(updated)")
        updatedLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        updatedLabel.textColor = UsageFormatting.secondaryText
        updatedLabel.alignment = .right
        updatedLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.maximumNumberOfLines = 1

        updatedLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.addSubview(updatedLabel)
        NSLayoutConstraint.activate([
            updatedLabel.trailingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: -2),
            updatedLabel.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            updatedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: refreshButton.leadingAnchor, constant: 170),
        ])
        refreshButton.toolTip = "Refresh usage for every account"
        return refreshButton
    }

    @available(macOS 13.0, *)
    private func launchAtLoginRow() -> NSView {
        let row = NSView()
        let label = textLabel(
            "Launch at Login",
            font: .systemFont(ofSize: 12.5, weight: .medium),
            color: UsageFormatting.primaryText
        )
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleLaunchAtLogin(_:))
        let isEnabled = SMAppService.mainApp.status == .enabled
        toggle.state = isEnabled ? .on : .off
        toggle.toolTip = "Launch Overseer when you log in"
        let stateLabel = textLabel(
            isEnabled ? "On" : "Off",
            font: .monospacedSystemFont(ofSize: 10.5, weight: .semibold),
            color: isEnabled ? UsageFormatting.primaryText : UsageFormatting.secondaryText
        )
        stateLabel.identifier = NSUserInterfaceItemIdentifier("launch-at-login-state")
        stateLabel.alignment = .right

        label.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(stateLabel)
        row.addSubview(toggle)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            stateLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stateLabel.widthAnchor.constraint(equalToConstant: 22),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func textLabel(_ title: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func addSeparator(to stack: NSStackView) {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = UsageFormatting.divider.cgColor
        addFullWidth(separator, to: stack, height: 1)
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSButton {
        let button = HoverButton(title: title, target: self, action: action)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 12.5, weight: .medium)
        button.contentTintColor = UsageFormatting.primaryText
        button.keyEquivalent = keyEquivalent
        button.focusRingType = .default
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        return button
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView, height: CGFloat) {
        stack.addArrangedSubview(view)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(macOS 13.0, *)
    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Couldn’t update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        if let stateLabel = sender.superview?.subviews.first(where: {
            $0.identifier?.rawValue == "launch-at-login-state"
        }) as? NSTextField {
            let isEnabled = sender.state == .on
            stateLabel.stringValue = isEnabled ? "On" : "Off"
            stateLabel.textColor = isEnabled
                ? UsageFormatting.primaryText
                : UsageFormatting.secondaryText
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
