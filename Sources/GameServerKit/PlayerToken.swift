import Foundation

/// Opaque per-player session credential, issued at room create/join. Passed back on the
/// WebSocket upgrade (and any host-gated REST calls) to re-attach to an existing player
/// without re-running the join flow.
public struct PlayerToken: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init() {
        self.value = Self.generate()
    }

    public init(value: String) {
        self.value = value
    }

    public var description: String { value }

    /// 24 random bytes as URL-safe base64 (RFC 4648 §5). A raw "+" or "/" in a query-string
    /// value gets form-urlencoded-decoded (+ -> space) by the server's query parser, silently
    /// corrupting the token and failing auth; never producing those characters avoids the whole
    /// class of bug.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
