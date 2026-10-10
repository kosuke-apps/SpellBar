import Foundation
import OSLog

/// The app's logs. They record rare events that explain later misbehaviour — a repaired window, a dead event
/// tap, the permission state at launch — and never anything the user typed.
///
/// Read them with:
/// `/usr/bin/log show --last 5m --predicate 'subsystem == "dev.kosuke.SpellBar"'`
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.kosuke.SpellBar"
    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let runtime = Logger(subsystem: subsystem, category: "runtime")
}
