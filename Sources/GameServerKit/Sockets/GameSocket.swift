import Foundation
import Vapor

/// The part of a game's WebSocket upgrade that is the same for every game: find the room, check
/// `?playerId&token`, and wire the liveness signals. What happens on a text frame and on close
/// stays with the game, since that is the whole of its protocol.
public enum GameSocket {
    public struct Session<Room: GameRoom>: Sendable {
        public let room: Room
        public let playerId: UUID
        public let code: String
    }

    /// Nil when the upgrade was refused; the socket has already been told why and closed.
    /// `errorText` renders the game's own `{"type":"error",...}` frame.
    public static func authenticate<Room: GameRoom>(
        req: Request, ws: WebSocket,
        room: (String) async -> Room?,
        validateToken: (Room, UUID, String) async -> Bool,
        errorText: (String) -> String
    ) async -> Session<Room>? {
        guard let code = req.parameters.get("code"), let found = await room(code) else {
            try? await ws.send(errorText("Room not found"))
            try? await ws.close(code: .unacceptableData)
            return nil
        }
        guard let idString = req.query[String.self, at: "playerId"], let playerId = UUID(uuidString: idString),
              let token = req.query[String.self, at: "token"] else {
            try? await ws.send(errorText("Missing playerId or token"))
            try? await ws.close(code: .policyViolation)
            return nil
        }
        guard await validateToken(found, playerId, token) else {
            try? await ws.send(errorText("Invalid player token"))
            try? await ws.close(code: .policyViolation)
            return nil
        }
        return Session(room: found, playerId: playerId, code: code)
    }

    /// Pings and pongs are the only evidence the server gets that a socket's peer is still alive —
    /// a client that dies without a close frame simply stops pinging — so both feed `noteAlive`,
    /// and ping arrival gaps go to `NetDiagnostics` (a healthy client logs nothing).
    public static func wireLiveness(
        _ ws: WebSocket, room: String, playerName: String, noteAlive: @escaping @Sendable () async -> Void
    ) {
        ws.onPing { _, _ in
            await NetDiagnostics.shared.recordPing(room: room, player: playerName)
            await noteAlive()
        }
        ws.onPong { _, _ in await noteAlive() }
    }
}
