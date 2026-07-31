import Foundation

/// A room a `RoomRegistry` can manage the lifecycle of. `code` is expected to be
/// stable/`nonisolated` on actor conformers; `hasAnyConnection`/`lastActivityAt` are
/// declared `async` so both actors and plain value types can conform.
public protocol GameRoom: Sendable {
    var code: String { get }
    var hasAnyConnection: Bool { get async }
    var lastActivityAt: Date { get async }

    /// Whether this room should be discoverable in a public lobby listing rather than
    /// requiring the room code. Defaults to `false` below for existing conformers.
    var isPublic: Bool { get async }
}

public extension GameRoom {
    var isPublic: Bool { false }
}
