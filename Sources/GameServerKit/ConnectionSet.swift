import Foundation
import Vapor

/// A room's set of live WebSocket connections, keyed by a connection id (not player id —
/// the same player may reconnect with a new socket). Handles JSON encode + broadcast/send.
public actor ConnectionSet {
    private var connections: [UUID: WebSocket] = [:]
    private let encoder: JSONEncoder

    public init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    public var isEmpty: Bool { connections.isEmpty }
    public var count: Int { connections.count }

    @discardableResult
    public func add(_ socket: WebSocket) -> UUID {
        let id = UUID()
        connections[id] = socket
        return id
    }

    public func remove(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    public func broadcast<T: Encodable>(_ message: T) {
        guard let text = encodeText(message) else { return }
        for socket in connections.values {
            Task { try? await socket.send(text) }
        }
    }

    public func send<T: Encodable>(_ message: T, to id: UUID) async {
        guard let socket = connections[id], let text = encodeText(message) else { return }
        try? await socket.send(text)
    }

    private func encodeText<T: Encodable>(_ message: T) -> String? {
        guard let data = try? encoder.encode(message) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
