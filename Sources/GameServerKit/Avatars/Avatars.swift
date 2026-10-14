import Foundation
import Vapor

/// The faces people pick for themselves: a fixed menu of emoji, nothing uploaded. A preset list
/// keeps avatars out of user-generated-content territory (nothing to moderate) and renders the
/// same on every client. The list is the server's — a client can only choose from it — and is
/// served by `GET /api/v1/avatars` so a client never ships one the server would refuse.
public enum Avatars {
    public static let all: [String] = [
        // Animals
        "🦊", "🐸", "🐙", "🦄", "🐼", "🐨", "🐯", "🦁", "🐷", "🐵", "🙈", "🦉",
        "🐧", "🦖", "🐢", "🦀", "🦩", "🦥", "🦦", "🦔", "🐝", "🐳", "🦭", "🐌",
        // Weird and wonderful
        "👽", "👾", "🤖", "👻", "💀", "🤡", "🎃", "🥸", "🤠", "🧙", "🧛", "🥷",
        "🦸", "🧌", "🧞", "🐲",
        // Things
        "🍕", "🌮", "🍩", "🥑", "🍄", "🌵", "🔥", "🌈", "🎩", "🎲", "🃏", "💩",
    ]
    static let allowed = Set(all)

    public static func isValid(_ avatar: String) -> Bool { allowed.contains(avatar) }
}

/// Who picked which face, keyed by `PublicPersonID` (so it follows linked devices) and persisted
/// as one line per change, the last line per person winning on reload.
public actor AvatarStore {
    struct Row: Codable { let personId: String; let avatar: String? }

    private let file: JSONLinesFile<Row>
    private var byPerson: [String: String]?

    public init(fileURL: URL = URL(fileURLWithPath: "player_avatars.jsonl")) {
        file = JSONLinesFile(url: fileURL)
    }

    public func avatar(for personId: String?) -> String? {
        guard let personId else { return nil }
        load()
        return byPerson?[personId]
    }

    /// Every pick at once, keyed by `PublicPersonID`, for decorating a leaderboard or a history page.
    public func all() -> [String: String] {
        load()
        return byPerson ?? [:]
    }

    /// Nil clears it back to the initial-letter disc.
    public func set(_ avatar: String?, for personId: String) {
        load()
        byPerson?[personId] = avatar
        file.append(Row(personId: personId, avatar: avatar))
    }

    private func load() {
        guard byPerson == nil else { return }
        var map: [String: String] = [:]
        for row in file.load() { map[row.personId] = row.avatar }
        byPerson = map
    }
}

/// `GET  /api/v1/avatars`            — the menu.
/// `GET  /api/v1/avatar?key=`        — this player's pick, `{avatar}` (null when none).
/// `POST /api/v1/avatar {key, avatar}` — pick one from the menu, or null to clear.
public struct AvatarRoutes: RouteCollection, Sendable {
    public let store: AvatarStore
    public let identities: PlayerIdentityStore

    public init(store: AvatarStore, identities: PlayerIdentityStore) {
        self.store = store
        self.identities = identities
    }

    public struct Pick: Content {
        public let key: String
        public var avatar: String?
    }
    public struct Current: Content {
        public let avatar: String?
    }

    public func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")
        api.get("avatars") { _ in Avatars.all }
        api.get("avatar", use: current)
        api.post("avatar", use: pick)
    }

    func current(req: Request) async throws -> Current {
        guard let key = PlayerKeys.sanitized(try? req.query.get(String.self, at: "key")) else {
            throw Abort(.badRequest, reason: "key is required")
        }
        return Current(avatar: await store.avatar(for: await PublicPersonID.of(key: key, identities: identities)))
    }

    func pick(req: Request) async throws -> Current {
        let body = try req.content.decode(Pick.self)
        guard let key = PlayerKeys.sanitized(body.key) else { throw Abort(.badRequest, reason: "key is required") }
        if let avatar = body.avatar, !Avatars.isValid(avatar) { throw Abort(.badRequest, reason: "Not one of the avatars.") }
        await store.set(body.avatar, for: await PublicPersonID.of(key: key, identities: identities))
        return Current(avatar: body.avatar)
    }
}
