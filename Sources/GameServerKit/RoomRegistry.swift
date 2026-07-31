import Foundation

/// Generic in-memory registry of active rooms, keyed by a short room code. Pure in-memory,
/// no persistence — rooms are garbage-collected some time after their last activity with
/// no live connections (see `cleanupStaleRooms()`).
///
/// Works for either an actor-based `Room` (own its own isolation, e.g. BombBustersAPI's
/// engine) or a value-type `Room` mutated through `withRoom(_:_:)` (e.g. a simple struct
/// snapshot store) — `GameRoom`'s `async` requirements are satisfiable either way.
public actor RoomRegistry<Room: GameRoom> {
    private var rooms: [String: Room] = [:]
    private let codeAlphabet: [Character]
    private let codeLength: Int
    private let staleAfter: TimeInterval

    /// - Parameters:
    ///   - codeAlphabet: characters usable in a generated room code. Default excludes
    ///     visually-ambiguous characters (0/O/1/I). Pass e.g. `"0123456789"` for a
    ///     numeric-only code.
    ///   - codeLength: number of characters per generated code.
    ///   - staleAfter: how long a room may sit with no live connections before
    ///     `cleanupStaleRooms()` drops it.
    public init(
        codeAlphabet: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789",
        codeLength: Int = 4,
        staleAfter: TimeInterval = 24 * 60 * 60
    ) {
        self.codeAlphabet = Array(codeAlphabet)
        self.codeLength = codeLength
        self.staleAfter = staleAfter
    }

    /// Reserves a fresh unique code and hands it to `makeRoom` to construct the room,
    /// which is then stored under that code.
    public func createRoom(_ makeRoom: (String) async throws -> Room) async rethrows -> Room {
        let code = generateUniqueCode()
        let room = try await makeRoom(code)
        rooms[code] = room
        return room
    }

    public func room(for code: String) -> Room? {
        rooms[code.uppercased()]
    }

    public func removeRoom(for code: String) {
        rooms.removeValue(forKey: code.uppercased())
    }

    /// Read-modify-write helper for value-type `Room`s: looks the room up, hands it to
    /// `body` as `inout`, and writes the (possibly mutated) result back. Returns `nil` if
    /// no room exists for `code`.
    public func withRoom<T>(_ code: String, _ body: (inout Room) throws -> T) rethrows -> T? {
        guard var room = rooms[code.uppercased()] else { return nil }
        defer { rooms[code.uppercased()] = room }
        return try body(&room)
    }

    /// Rooms currently flagged `isPublic`, for a lobby-listing endpoint. Returns the rooms
    /// themselves rather than a DTO — callers map each into their own game-specific summary
    /// (player count, state, host name, etc.), since the registry has no notion of gameplay.
    public func publicRooms() async -> [Room] {
        var result: [Room] = []
        for room in rooms.values {
            if await room.isPublic {
                result.append(room)
            }
        }
        return result
    }

    private func generateUniqueCode() -> String {
        while true {
            let code = String((0..<codeLength).map { _ in codeAlphabet.randomElement()! })
            if rooms[code] == nil { return code }
        }
    }

    /// Drops rooms with no active connections that have been idle past the TTL. Call this
    /// periodically from a background task — see `EventLoopGroup.scheduleRoomCleanup(_:)`.
    public func cleanupStaleRooms() async {
        var toRemove: [String] = []
        for (code, room) in rooms {
            guard await !room.hasAnyConnection else { continue }
            if Date().timeIntervalSince(await room.lastActivityAt) > staleAfter {
                toRemove.append(code)
            }
        }
        for code in toRemove {
            rooms.removeValue(forKey: code)
        }
    }
}
