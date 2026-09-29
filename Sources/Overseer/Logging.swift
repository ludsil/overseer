import Foundation
import os

/// Overseer logs almost nothing to the user, so when a token silently dies or a fetch
/// keeps failing there is normally no trace to look at. These categories make the
/// credential and fetch paths observable without exposing secrets: emails and tokens are
/// interpolated `.private`, so they are redacted in `log show`/`log stream` unless the
/// machine is explicitly configured to reveal private data.
///
/// Inspect with:  log stream --predicate 'subsystem == "com.ludsil.overseer"'
enum Log {
    private static let subsystem = "com.ludsil.overseer"

    /// Usage/profile HTTP: statuses, retries, what got substituted from cache.
    static let fetch = Logger(subsystem: subsystem, category: "fetch")
    /// Which account a row resolved to, and whether it was verified against the token.
    static let identity = Logger(subsystem: subsystem, category: "identity")
    /// Keychain reads/writes/deletes and OAuth refreshes — the same-day-logout surface.
    static let credential = Logger(subsystem: subsystem, category: "credential")
    /// Account swaps, parks, and their read-back verification.
    static let account = Logger(subsystem: subsystem, category: "account")
}
