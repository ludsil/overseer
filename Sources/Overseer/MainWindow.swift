import AppKit

/// A real window showing the same usage content as the popover.
///
/// The menu bar item is one way in, not the only one: macOS can park a status item behind the
/// camera housing or drop it when the bar is full, and the app looks dead even though it is fine.
/// Reopening Overseer from Finder lands here instead of doing nothing.
final class OverseerWindowController: NSWindowController {
    private let build: () -> NSViewController
    private let diagnostics: () -> String
    private var hosted: NSViewController?

    init(build: @escaping () -> NSViewController, diagnostics: @escaping () -> String) {
        self.build = build
        self.diagnostics = diagnostics
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Overseer"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(explainMenuBar: Bool) {
        guard let window else { return }
        let wasVisible = window.isVisible
        install(container(explainMenuBar: explainMenuBar), in: window)
        if !wasVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible() {
        guard let window, window.isVisible else { return }
        let explaining = window.contentViewController?.view.subviews.contains {
            $0.identifier == Self.bannerIdentifier
        } ?? false
        install(container(explainMenuBar: explaining), in: window)
    }

    /// The content sizes itself; the window follows it rather than stretching it.
    private func install(_ controller: NSViewController, in window: NSWindow) {
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let height = controller.view.fittingSize.height
        window.setContentSize(NSSize(width: Self.contentWidth, height: max(160, height)))
    }

    private static let contentWidth: CGFloat = 420

    private static let bannerIdentifier = NSUserInterfaceItemIdentifier("menu-bar-banner")

    private func container(explainMenuBar: Bool) -> NSViewController {
        let content = build()
        hosted = content

        let root = NSVisualEffectView()
        root.appearance = NSAppearance(named: .darkAqua)
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        if explainMenuBar {
            let banner = menuBarBanner()
            banner.identifier = Self.bannerIdentifier
            stack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        stack.addArrangedSubview(content.view)
        content.view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let controller = NSViewController()
        controller.view = root
        controller.addChild(content)
        return controller
    }

    private func menuBarBanner() -> NSView {
        let box = NSView()

        let title = label(
            "Overseer is running",
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: UsageFormatting.primaryText
        )
        let body = label(
            "Look for the icon in the menu bar. If it is not there, the bar may be full or the "
                + "icon may be sitting behind the camera notch. Usage still updates, and this "
                + "window always shows it.",
            font: .systemFont(ofSize: 11.5, weight: .regular),
            color: UsageFormatting.secondaryText
        )
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.preferredMaxLayoutWidth = Self.contentWidth - 32

        let copy = NSButton(
            title: "Copy diagnostics",
            target: self,
            action: #selector(copyDiagnostics)
        )
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: 11.5, weight: .medium)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = UsageFormatting.divider.cgColor

        for view in [title, body, copy, divider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            copy.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 9),
            copy.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            divider.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        return field
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }
}

/// What the app can observe about its own status item.
///
/// `isVisible` is not a visibility check: it stays `true` both when macOS suppresses the item for
/// lack of space (documented) and when the item sits behind the notch (measured). Geometry against
/// the notch-safe areas catches the notch case only, so the result is "suspicious", never "hidden".
enum StatusItemDiagnostics {
    static func assignedRect(for item: NSStatusItem) -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    static func isSuspicious(_ item: NSStatusItem) -> Bool {
        guard let rect = assignedRect(for: item) else { return true }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else {
            return true
        }
        let unobscured = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
        guard !unobscured.isEmpty else { return !screen.frame.contains(rect) }
        return !unobscured.contains { $0.contains(rect) }
    }

    static func report(for item: NSStatusItem, profiles: Int) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "Overseer \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "profiles: \(profiles)",
            "statusItem.isVisible: \(item.isVisible)",
            "suspicious placement: \(isSuspicious(item))",
        ]
        if let rect = assignedRect(for: item) {
            lines.append("assigned rect: \(short(rect))")
        } else {
            lines.append("assigned rect: none (no button window)")
        }
        if let screen = NSScreen.main {
            lines.append("screen: \(short(screen.frame))")
            lines.append("safeAreaInsets.top: \(screen.safeAreaInsets.top)")
            lines.append("auxTopLeft: \(screen.auxiliaryTopLeftArea.map(short) ?? "nil")")
            lines.append("auxTopRight: \(screen.auxiliaryTopRightArea.map(short) ?? "nil")")
        }
        let key = "NSStatusItem Preferred Position Item-0"
        lines.append("preferred position: \(UserDefaults.standard.object(forKey: key) ?? "unset")")
        return lines.joined(separator: "\n")
    }

    private static func short(_ rect: NSRect) -> String {
        "x\(Int(rect.origin.x)) y\(Int(rect.origin.y)) w\(Int(rect.width)) h\(Int(rect.height))"
    }
}
