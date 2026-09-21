import Foundation
import Vapor

/// `GET /api/v1/players` — everyone the server has seen, newest first, with what they were
/// holding. An operator view, same trust tier as `rooms/admin`: no auth, keys masked.
///
/// - Parameter roomIsLive: whether a room code still exists, so `inRoom` only names a table that
///   is actually going.
public struct PlayersRoutes: RouteCollection, Sendable {
    public struct Player: Content, Sendable {
        public let name: String
        /// Last six characters of the key — enough to tell "Joe on the Mac" from "Joe on the iPad".
        public let keySuffix: String
        public let platform: String?
        public let app: String?
        public let os: String?
        public let device: String?
        public let host: String?
        public let summary: String
        public let lastSeenAt: Date
        public let firstSeenAt: Date
        /// The table they last sat at, if it is still live.
        public let inRoom: String?
        /// How many devices link into this person (1 = unlinked).
        public let linkedDevices: Int
    }

    public let devices: DeviceRegistry
    public let identities: PlayerIdentityStore
    public let roomIsLive: @Sendable (String) async -> Bool

    public init(devices: DeviceRegistry, identities: PlayerIdentityStore, roomIsLive: @escaping @Sendable (String) async -> Bool) {
        self.devices = devices
        self.identities = identities
        self.roomIsLive = roomIsLive
    }

    public func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "v1").get("players", use: list)
    }

    func list(req: Request) async throws -> [Player] {
        let limit = max(1, min((try? req.query.get(Int.self, at: "limit")) ?? 200, 1000))
        let counts = await identities.keyCountsByIdentity()
        let ids = await identities.identityIdsByKey()
        var out: [Player] = []
        for rec in await devices.all().prefix(limit) {
            let live: String?
            if let code = rec.lastRoomCode, await roomIsLive(code) { live = code } else { live = nil }
            let c = rec.client
            out.append(Player(
                name: rec.name, keySuffix: String(rec.key.suffix(6)),
                platform: c?.platform, app: c?.app, os: c?.os, device: c?.device, host: c?.host,
                summary: c?.summary ?? "unknown (client predates X-Client)",
                lastSeenAt: rec.lastSeenAt, firstSeenAt: rec.firstSeenAt, inRoom: live,
                linkedDevices: ids[rec.key].flatMap { counts[$0] } ?? 1
            ))
        }
        return out
    }
}
