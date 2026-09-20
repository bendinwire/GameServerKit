import Foundation
import Vapor

/// Sending over WebSockets that may be half-dead.
///
/// A socket whose peer went to sleep, switched networks, or silently lost Wi-Fi is a TCP
/// connection the kernel still thinks is open: `send()` blocks until the OS's own retransmission
/// timeout gives up, commonly 1-2 minutes. Left alone, THAT player (and, in a serial loop, every
/// player behind them) receives nothing for that long — the "stuck for over a minute, then it
/// finally goes through" pattern reported live in Quadfecta. Every send here races a short
/// deadline instead, fans out in parallel so one bad socket costs only its own seat, and closes
/// a socket that blew the deadline so the client's reconnect (seconds) takes over from the
/// kernel's timeout (minutes).
public enum SocketSends {
    public static let deadline: TimeInterval = 4

    /// True if the send completed within the deadline.
    public static func withDeadline(_ socket: WebSocket, _ text: String, seconds: TimeInterval = deadline) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await socket.send(text)) != nil }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    public struct Outbound: Sendable {
        public let id: UUID
        public let socket: WebSocket
        public let text: String
        public init(id: UUID, socket: WebSocket, text: String) {
            self.id = id; self.socket = socket; self.text = text
        }
    }

    /// Sends every message in parallel, records each one's timing in `NetDiagnostics`, and
    /// closes any socket that missed the deadline. Awaited as a group rather than fired and
    /// forgotten so successive broadcasts cannot interleave out of order on one socket.
    /// Returns the ids whose socket was closed, so the room can treat them as dropped.
    @discardableResult
    public static func fanOut(
        _ messages: [Outbound], room: String, operation: String = "broadcast",
        name: @escaping @Sendable (UUID) -> String
    ) async -> [UUID] {
        guard !messages.isEmpty else { return [] }
        var timedOut: [UUID] = []
        await withTaskGroup(of: UUID?.self) { group in
            for m in messages {
                group.addTask {
                    let started = Date()
                    let ok = await withDeadline(m.socket, m.text)
                    await NetDiagnostics.shared.record(
                        room: room, player: name(m.id), operation: ok ? operation : "\(operation)_timeout",
                        seconds: Date().timeIntervalSince(started)
                    )
                    if !ok { Task { try? await m.socket.close(code: .goingAway) } }
                    return ok ? nil : m.id
                }
            }
            for await id in group { if let id { timedOut.append(id) } }
        }
        return timedOut
    }
}
