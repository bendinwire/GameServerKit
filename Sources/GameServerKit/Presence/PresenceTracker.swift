import Foundation
import Vapor

/// Who is actually here: the per-seat socket bookkeeping every room needs and gets subtly wrong
/// on its own. Owned by the room actor as a plain value; it holds no isolation of its own.
///
/// Three facts per seat, and the reasons each exists:
///
/// - **The socket.** A reconnect supersedes the old one, and the old one's `onClose` can fire
///   AFTER the new one attached. `detach` therefore matches on socket identity, so a stale close
///   never evicts the live connection.
/// - **When we last heard from it.** A client that vanishes without a close frame (force-quit,
///   lid shut, Wi-Fi gone) leaves the TCP connection nominally open for a long time. Without a
///   liveness clock the room looks occupied forever: advertised in the lobby, skipped by the GC.
/// - **When it disconnected.** Lobby seats are held for a grace window and then reaped; a seat
///   is stamped disconnected the moment it is created, so a join whose socket never arrives
///   ages out on the same clock as one that dropped later.
public struct PresenceTracker: Sendable {
    public private(set) var sockets: [UUID: WebSocket] = [:]
    private var lastHeardFrom: [UUID: Date] = [:]
    public private(set) var disconnectedAt: [UUID: Date] = [:]
    /// Whether ANY socket has ever attached. Distinguishes a genuinely new room (host handshake
    /// still in flight) from an abandoned one that merely has recent activity.
    public private(set) var hasEverHadConnection = false

    /// A socket silent for this long has no one behind it. Generous next to a client that pings
    /// every couple of seconds, so a briefly stalled sender is never mistaken for a dead one.
    public var socketSilenceTimeout: TimeInterval = 45

    public init() {}

    public var hasAnyConnection: Bool { !sockets.isEmpty }
    public func isConnected(_ id: UUID) -> Bool { sockets[id] != nil }

    /// A seat exists now; nobody is on it yet.
    public mutating func seatCreated(_ id: UUID, now: Date = Date()) {
        disconnectedAt[id] = now
    }

    /// Returns the socket that was superseded, if any, so the caller can close it. An
    /// abandoned-but-open socket is exactly the kind of stalled write that holds up a broadcast.
    @discardableResult
    public mutating func attach(_ id: UUID, socket: WebSocket, now: Date = Date()) -> WebSocket? {
        hasEverHadConnection = true
        let previous = sockets[id]
        sockets[id] = socket
        lastHeardFrom[id] = now
        disconnectedAt[id] = nil
        return (previous != nil && previous !== socket) ? previous : nil
    }

    /// `socket` is the connection that actually closed; nil means "drop whatever is current".
    /// Returns false when the close belonged to a superseded socket and the live one stays.
    @discardableResult
    public mutating func detach(_ id: UUID, socket: WebSocket? = nil, now: Date = Date()) -> Bool {
        if let socket, let current = sockets[id], current !== socket { return false }
        sockets.removeValue(forKey: id)
        lastHeardFrom.removeValue(forKey: id)
        disconnectedAt[id] = now
        return true
    }

    /// Any inbound frame is the only evidence the peer is alive.
    public mutating func noteAlive(_ id: UUID, now: Date = Date()) {
        guard sockets[id] != nil else { return }
        lastHeardFrom[id] = now
    }

    public mutating func forget(_ id: UUID) {
        sockets[id] = nil
        lastHeardFrom[id] = nil
        disconnectedAt[id] = nil
    }

    public mutating func removeAll() {
        sockets.removeAll()
        lastHeardFrom.removeAll()
    }

    /// Seats whose socket has gone silent past the timeout. The caller detaches them and closes
    /// the socket; it must NOT count that as room activity, or a reaped zombie buys the abandoned
    /// room a fresh idle window.
    public func zombies(now: Date = Date()) -> [UUID] {
        sockets.keys.filter { now.timeIntervalSince(lastHeardFrom[$0] ?? now) > socketSilenceTimeout }
    }

    /// How long `id` has been away, or nil if connected.
    public func awayFor(_ id: UUID, now: Date = Date()) -> TimeInterval? {
        guard sockets[id] == nil, let since = disconnectedAt[id] else { return nil }
        return now.timeIntervalSince(since)
    }
}
