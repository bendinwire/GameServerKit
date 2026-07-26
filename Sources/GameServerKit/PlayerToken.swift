import Foundation

/// Opaque per-player session credential, issued at room create/join. Passed back on the
/// WebSocket upgrade (and any host-gated REST calls) to re-attach to an existing player
/// without re-running the join flow.
public struct PlayerToken: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init() {
        self.value = UUID().uuidString
    }

    public init(value: String) {
        self.value = value
    }

    public var description: String { value }
}
