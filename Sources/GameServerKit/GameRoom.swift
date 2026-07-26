import Foundation

/// A room a `RoomRegistry` can manage the lifecycle of. `code` is expected to be
/// stable/`nonisolated` on actor conformers; `hasAnyConnection`/`lastActivityAt` are
/// declared `async` so both actors and plain value types can conform.
public protocol GameRoom: Sendable {
    var code: String { get }
    var hasAnyConnection: Bool { get async }
    var lastActivityAt: Date { get async }
}
