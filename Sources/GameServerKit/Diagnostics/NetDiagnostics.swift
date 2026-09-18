import Foundation
import Vapor

/// Ring buffer of recent slow operations, readable over HTTP at `GET /api/v1/diagnostics`.
///
/// Exists because "the game feels laggy" is otherwise unfalsifiable from the outside: the stall
/// could be the server holding a socket, one client's connection stalling, or that client's own
/// render loop. Timing each send AT THE SERVER and attributing it to a player settles which,
/// without needing shell access to read journald.
///
/// Deliberately records only operations SLOWER than a threshold — a healthy game writes nothing,
/// so anything in here is a real observation rather than noise to sift.
public actor NetDiagnostics {
    public static let shared = NetDiagnostics()

    public init() {}

    public struct Event: Content, Sendable {
        public let at: String
        public let room: String
        public let player: String
        public let operation: String
        public let milliseconds: Int
    }

    /// Below this, a send is unremarkable — LAN and WAN round trips both land well under it.
    public static let slowThreshold: TimeInterval = 0.25

    /// TEMP DIAGNOSTIC — the client pings every 2s (see the client's WebSocketConnection). A gap
    /// comfortably above that between two pings from the same player means the pings are NOT
    /// leaving that Mac on schedule — stretched timers / a throttled process — which is itself
    /// the finding. Regular ~2s gaps combined with still-late deliveries would instead kill the
    /// radio-doze theory outright.
    public static let pingGapThreshold: TimeInterval = 3.5

    private var lastPingAt: [String: Date] = [:]

    public func recordPing(room: String, player: String) {
        let key = "\(room)/\(player)"
        let now = Date()
        defer { lastPingAt[key] = now }
        guard let previous = lastPingAt[key] else { return }
        let gap = now.timeIntervalSince(previous)
        guard gap >= Self.pingGapThreshold else { return }
        events.append(Event(
            at: formatter.string(from: now), room: room, player: player,
            operation: "ping_gap", milliseconds: Int(gap * 1000)
        ))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    private var events: [Event] = []
    private let capacity = 300
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public func record(room: String, player: String, operation: String, seconds: TimeInterval) {
        guard seconds >= Self.slowThreshold else { return }
        events.append(Event(
            at: formatter.string(from: Date()),
            room: room,
            player: player,
            operation: operation,
            milliseconds: Int(seconds * 1000)
        ))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func recent(limit: Int) -> [Event] {
        Array(events.suffix(limit))
    }

    public func clear() {
        events.removeAll()
    }
}
