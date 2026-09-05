import Foundation

/// What to call a profile in the UI.
///
/// An account is named by its own address, so Claude rows never need this. Codex and Grok hold
/// one account each, which makes the engine the distinguishing fact, and an unmounted profile
/// has no address to show yet - those are the only cases left. Config directories stay an
/// implementation detail, visible only in tooltips.
enum SlotNames {
    static func name(for directory: String, engine: Engine) -> String {
        switch engine {
        case .claude:
            if ClaudeSession.isDefault(directory) { return "Main" }
        case .codex:
            let home = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
            if URL(fileURLWithPath: directory).standardized.path
                == URL(fileURLWithPath: home).standardized.path { return "Codex" }
        case .grok:
            let home = (NSHomeDirectory() as NSString).appendingPathComponent(".grok")
            if URL(fileURLWithPath: directory).standardized.path
                == URL(fileURLWithPath: home).standardized.path { return "Grok" }
        }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}
