import AppKit

final class UsageBarView: NSView {
    private let fraction: CGFloat
    private let fillColor: NSColor

    init(percent: Double?, color: NSColor) {
        fraction = CGFloat(min(100, max(0, percent ?? 0)) / 100)
        fillColor = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Usage")
        setAccessibilityValue(percent.map { "\(Int($0)) percent" } ?? "Unknown")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        UsageFormatting.track.setFill()
        track.fill()

        guard fraction > 0 else { return }
        let width = max(4, floor(bounds.width * fraction))
        let fillRect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2)
        fillColor.setFill()
        fill.fill()
    }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class HoverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = UsageFormatting.hoverSurface.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}
