import Foundation
import Logging

/// Whether the server's flat files are actually being written, for `/health` and the logs.
///
/// Exists because of 2026-09-23 → 10-13: a command run as root rewrote both games' history files,
/// leaving them root-owned and read-only to the service user. Every append after that failed, and
/// for twenty days nothing said so — `JSONLinesFile` threw its errors away, `HistoryLog` still put
/// each game in its in-memory cache, so History and the leaderboards looked right until the next
/// deploy restarted the service and the games were gone. fleet-check stayed green throughout.
///
/// So a write failure is now loud twice over: an error-level log line carrying the fixed marker
/// `persistence write failed` (grep-able, whatever the log format), and a per-file entry here that
/// the health routes report until that same file is written successfully again.
public final class PersistenceHealth: @unchecked Sendable {
    public static let shared = PersistenceHealth()

    private let lock = NSLock()
    /// Absolute path → what last went wrong writing it. Empty means every file is writable.
    private var failures: [String: String] = [:]

    /// `"ok"`, or `"failing: <file>, <file>"` — file names only, no paths, since this is served on
    /// an unauthenticated route.
    public var status: String {
        lock.lock(); defer { lock.unlock() }
        guard !failures.isEmpty else { return "ok" }
        let names = failures.keys.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        return "failing: " + names.joined(separator: ", ")
    }

    /// Record that `url` could not be written, and log it at error level.
    public func failed(_ url: URL, _ action: String, _ error: any Error) {
        let path = url.path
        // One line: journald splits a message on newlines, and Foundation's error descriptions
        // run to several on Darwin — the marker would land on the first and the cause on others.
        let reason = String(describing: error).split(whereSeparator: \.isNewline).joined(separator: " ")
        lock.lock(); failures[path] = "\(action): \(reason)"; lock.unlock()
        Logger(label: "GameServerKit.persistence")
            .error("persistence write failed: could not \(action) \(path): \(reason)")
    }

    /// Record that `url` was written, clearing any failure against it.
    public func succeeded(_ url: URL) {
        let path = url.path
        lock.lock(); defer { lock.unlock() }
        if failures[path] != nil { failures[path] = nil }
    }
}

/// `rename(2)`'s errno, as an `Error` the failure log can print.
struct POSIXFailure: Error, CustomStringConvertible {
    let code: Int32
    var description: String { "\(String(cString: strerror(code))) (errno \(code))" }
}
