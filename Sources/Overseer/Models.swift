import AppKit
import Foundation

enum Engine: String, Codable {
    case claude
    case codex
    case grok
}

struct UsageLimit: Codable {
    let label: String
    let percent: Double?
    let severity: String
    let resetsAt: TimeInterval?
    var binding: Bool = false
}

struct UsageProfile: Codable {
    let engine: Engine
    let directory: String
    let name: String
    var email: String?
    var organization: String?
    var plan: String?
    var limits: [UsageLimit] = []
    var error: String?
    /// Informational, not a problem - e.g. a purchased-credits balance that keeps a
    /// full window usable.
    var note: String?
    var observedAt: TimeInterval?
    /// Stable identity of the account behind this directory, when it can be read.
    var accountKey: String?
    /// Set when an earlier slot already holds this account: this slot has no quota of its own.
    var sameAccountAs: String?
}

struct CachedLimits: Codable {
    let savedAt: TimeInterval
    let limits: [UsageLimit]
}

enum UsageFormatting {
    static let divider = NSColor.separatorColor.withAlphaComponent(0.58)
    static let track = NSColor.quaternaryLabelColor.withAlphaComponent(0.68)
    static let hoverSurface = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor

    // Provider hues are deliberately quieter than quota status colors. They help
    // the eye find account groups without competing with urgent usage states.
    static func providerColor(for engine: Engine) -> NSColor {
        switch engine {
        case .claude:
            return NSColor(
                srgbRed: 0.875,
                green: 0.635,
                blue: 0.494,
                alpha: 1
            )
        case .codex:
            return NSColor(
                srgbRed: 0.565,
                green: 0.725,
                blue: 0.847,
                alpha: 1
            )
        case .grok:
            return NSColor(
                srgbRed: 0.716,
                green: 0.682,
                blue: 0.859,
                alpha: 1
            )
        }
    }

    static func severity(for percent: Double?) -> String {
        guard let percent else { return "unknown" }
        if percent >= 80 { return "critical" }
        if percent >= 50 { return "warning" }
        return "normal"
    }

    static func color(for severity: String) -> NSColor {
        switch severity {
        case "normal":
            return NSColor(
                srgbRed: 0.400,
                green: 0.820,
                blue: 0.518,
                alpha: 1
            )
        case "warning":
            return NSColor(
                srgbRed: 0.937,
                green: 0.741,
                blue: 0.310,
                alpha: 1
            )
        case "critical":
            return NSColor(
                srgbRed: 0.941,
                green: 0.435,
                blue: 0.451,
                alpha: 1
            )
        default:
            return secondaryText
        }
    }

    static func resetDescription(_ timestamp: TimeInterval?) -> String? {
        guard let timestamp else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let delta = timestamp - Date().timeIntervalSince1970
        if delta < 0 { return "now" }

        let formatter = DateFormatter()
        if delta < 12 * 60 * 60, Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if delta < 6 * 24 * 60 * 60 {
            formatter.dateFormat = "EEE HH:mm"
        } else {
            formatter.dateFormat = "MMM d HH:mm"
        }
        return formatter.string(from: date)
    }

    static func ageDescription(_ timestamp: TimeInterval?) -> String? {
        guard let timestamp else { return nil }
        let delta = max(0, Date().timeIntervalSince1970 - timestamp)
        if delta < 90 { return "just now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}
