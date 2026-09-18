import Foundation

/// A `GameRoom` that knows its own lifecycle rules, so the registry can run one phase-aware
/// cleanup for every game rather than each API hand-writing the same three passes.
///
/// 1. `sweep()` runs first, so a room can reap zombie sockets and expired lobby seats. This
///    must come before anything else: a zombie socket makes a room look connected, and both
///    the listing and the GC skip connected rooms.
/// 2. An `isAbandoned` room goes immediately. Nothing can ever happen in it again.
/// 3. Everything else is dropped once idle past its own `idleTTL`, which a room decides by
///    phase: a game in progress is worth keeping for a day because its seats are resumable, an
///    empty lobby or a finished game is not.
public protocol ManagedGameRoom: GameRoom {
    func sweep() async
    var isAbandoned: Bool { get async }
    var idleTTL: TimeInterval { get async }
}

public extension RoomRegistry where Room: ManagedGameRoom {
    /// Returns the codes that were removed, so the caller can drop any side tables keyed by code.
    @discardableResult
    func cleanupManagedRooms(now: Date = Date()) async -> [String] {
        var doomed: [String] = []
        for room in allRooms() {
            await room.sweep()
            if await room.isAbandoned {
                doomed.append(room.code)
                continue
            }
            guard await !room.hasAnyConnection else { continue }
            let idle = now.timeIntervalSince(await room.lastActivityAt)
            if idle > (await room.idleTTL) { doomed.append(room.code) }
        }
        for code in doomed { removeRoom(for: code) }
        // The registry's own TTL pass stays as a backstop.
        await cleanupStaleRooms()
        return doomed
    }
}
