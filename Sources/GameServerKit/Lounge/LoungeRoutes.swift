import Foundation
import Vapor

/// `GET /api/v1/lounge` — who is here and the recent chat, for a client that has not connected yet.
/// `WS  /api/v1/lounge/ws?name=<display name>&key=<player key>` — join; the key groups a person's
/// devices (through the identity store when linked) and is never echoed to anyone.
///
/// Client → server: `{"type":"chat","text":"…"}`, `{"type":"ping"}`.
/// Server → client: `{"type":"lounge", people, chat}` on join; `{"type":"lounge_people", people}`
/// on arrivals/departures; `{"type":"lounge_chat", people, line}` per message; `{"type":"error", message}`.
public struct LoungeRoutes: RouteCollection, Sendable {
    public let lounge: Lounge
    public let identities: PlayerIdentityStore
    /// Records what each visitor is holding; nil to skip.
    public let devices: DeviceRegistry?

    public init(lounge: Lounge, identities: PlayerIdentityStore, devices: DeviceRegistry? = nil) {
        self.lounge = lounge
        self.identities = identities
        self.devices = devices
    }

    public func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "lounge")
        api.get { _ in await lounge.snapshot() }
        api.webSocket("ws", onUpgrade: handleWebSocket)
    }

    /// The same rules as a seat's name: 1–24 characters, and nothing the filter rejects.
    public static func cleanName(_ raw: String?) -> Result<String, Abort> {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...24).contains(name.count) else { return .failure(Abort(.badRequest, reason: "Name must be 1 to 24 characters")) }
        if let complaint = NameFilter.reason(name) { return .failure(Abort(.badRequest, reason: complaint)) }
        return .success(name)
    }

    func handleWebSocket(req: Request, ws: WebSocket) {
        Task {
            let name: String
            switch Self.cleanName(req.query[String.self, at: "name"]) {
            case .success(let n): name = n
            case .failure(let abort):
                try? await ws.send(await lounge.encode(.init(type: "error", message: abort.reason)))
                try? await ws.close(code: .policyViolation)
                return
            }
            // One row per person: the linked identity when there is one, the device key
            // otherwise, and a throwaway id for a client that sent no key at all.
            let personId: String
            if let key = PlayerKeys.sanitized(req.query[String.self, at: "key"]) {
                personId = await identities.identity(for: key)?.id.uuidString ?? key
                await devices?.note(key: key, name: name, client: req.clientInfo)
            } else {
                personId = "anon-\(UUID().uuidString)"
            }
            let id = await lounge.join(socket: ws, personId: personId, name: name)
            try? await ws.send(await lounge.encode(.init(type: "lounge", people: await lounge.snapshot().people, chat: await lounge.snapshot().chat)))
            await lounge.announceArrival()

            ws.onPing { _, _ in await lounge.noteAlive(id) }
            ws.onPong { _, _ in await lounge.noteAlive(id) }
            ws.onText { (_: WebSocket, text: String) async in
                await lounge.noteAlive(id)
                guard let msg = try? JSONDecoder().decode(Lounge.ClientMessage.self, from: Data(text.utf8)) else { return }
                switch msg.type {
                case "chat":
                    if await lounge.say(msg.text ?? "", from: id) == nil {
                        try? await ws.send(await lounge.encode(.init(type: "error", message: "Say something, up to \(Lounge.maxTextLength) characters.")))
                    }
                case "ping":
                    try? await ws.send(#"{"type":"pong"}"#)
                default:
                    break
                }
            }
            ws.onClose.whenComplete { _ in
                Task { await lounge.leave(id) }
            }
        }
    }
}
