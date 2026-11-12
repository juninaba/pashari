import Foundation
import os

/// Loggers for the unified system log, one per area of the app.
///
/// Read them in Console.app (filter by "io.github.juninaba.pashari"), or:
///
///     log stream --level debug --predicate 'subsystem == "io.github.juninaba.pashari"'
///
/// Like `console.log` in a browser, but the messages are kept by the system,
/// carry a timestamp and a category, and cost almost nothing when nobody is
/// reading them.
enum Log {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "Pashari"

    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let selection = Logger(subsystem: subsystem, category: "selection")
    nonisolated static let thumbnail = Logger(subsystem: subsystem, category: "thumbnail")
}
