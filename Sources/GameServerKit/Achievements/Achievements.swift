import Foundation
import Vapor

/// One achievement, as the game defines it. `id` is the permanent id registered with Game Center;
/// it can never change once live.
public struct AchievementDefinition: Content, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let points: Int
    public let group: String
    /// Stays secret until earned, on every client and in Game Center.
    public let hidden: Bool
    /// What `progress` has to reach. 1 for a one-off.
    public let target: Int

    public init(id: String, title: String, detail: String, points: Int, group: String, hidden: Bool = false, target: Int = 1) {
        self.id = id
        self.title = title
        self.detail = detail
        self.points = points
        self.group = group
        self.hidden = hidden
        self.target = target
    }
}

/// One finished game for one device key. Everything a person has earned is worked out from these
/// rows, so the rules can be tuned later without migrating anything, linked devices merge at read
/// time, and unlinking a device takes its games back out.
public struct AchievementRow<Record: Codable & Sendable>: Codable, Sendable {
    public let gameId: String
    public let key: String
    /// ISO 8601. Rows are read oldest first, because a streak is a thing that grew forwards.
    public let at: String
    public let record: Record

    public init(gameId: String, key: String, at: String, record: Record) {
        self.gameId = gameId
        self.key = key
        self.at = at
        self.record = record
    }
}

/// The per-seat game log behind achievements. One line per person per game. It is separate from
/// the history log because history has its own rule for what it keeps (Quadfecta leaves out solo
/// games) and because a row here is one person's, so "forget me" can simply delete it.
public actor AchievementLedger<Record: Codable & Sendable> {
    private let file: JSONLinesFile<AchievementRow<Record>>
    private var cache: [AchievementRow<Record>]?

    public init(fileURL: URL = URL(fileURLWithPath: "achievement_games.jsonl")) {
        file = JSONLinesFile(url: fileURL)
    }

    private func rows() -> [AchievementRow<Record>] {
        if let cache { return cache }
        let loaded = file.load()
        cache = loaded
        return loaded
    }

    /// Adds a row unless this person already has one for this game, so a history backfill can run
    /// on every boot. Returns whether it was added.
    @discardableResult
    public func append(_ row: AchievementRow<Record>) -> Bool {
        var all = rows()
        guard !all.contains(where: { $0.gameId == row.gameId && $0.key == row.key }) else { return false }
        all.append(row)
        cache = all
        file.append(row)
        return true
    }

    /// Every row for these keys, oldest first. The sort is stable, so same-second rows keep the
    /// order they were written in.
    public func rows(forKeys keys: [String]) -> [AchievementRow<Record>] {
        let wanted = Set(keys)
        return rows().filter { wanted.contains($0.key) }.sorted { $0.at < $1.at }
    }

    /// "Forget me": this key's games are gone. Returns how many rows went.
    @discardableResult
    public func forget(key: String) -> Int {
        let all = rows()
        let kept = all.filter { $0.key != key }
        guard kept.count != all.count else { return 0 }
        cache = kept
        file.rewrite(kept)
        return all.count - kept.count
    }
}

/// Collects a person's standing while a game's evaluator folds over their rows.
public struct AchievementTally: Sendable {
    public private(set) var progress: [String: Int] = [:]
    public private(set) var earnedAt: [String: String] = [:]
    public private(set) var scores: [String: Int] = [:]
    private let targets: [String: Int]

    public init(catalog: [AchievementDefinition]) {
        targets = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.target) })
    }

    /// Records a running value. The best value counts, so a streak that later breaks stays earned.
    public mutating func set(_ id: String, _ value: Int, at: String) {
        precondition(targets[id] != nil, "\(id) is not in the catalog")
        progress[id] = max(progress[id] ?? 0, value)
        if value >= targets[id, default: 1], earnedAt[id] == nil { earnedAt[id] = at }
    }

    /// Earns a one-off when `condition` holds.
    public mutating func earn(_ id: String, if condition: Bool, at: String) {
        if condition { set(id, 1, at: at) }
    }

    /// A Game Center leaderboard's current score. Higher is better on every board.
    public mutating func setScore(_ board: String, _ value: Int) {
        scores[board] = value
    }
}

/// `GET /api/v1/achievements?key=` — the catalog with this person's standing, across linked devices.
public struct AchievementRoutes<Record: Codable & Sendable>: RouteCollection, Sendable {
    public let catalog: [AchievementDefinition]
    public let ledger: AchievementLedger<Record>
    public let identities: PlayerIdentityStore
    /// Folds a person's rows, oldest first, into a tally.
    public let evaluate: @Sendable ([AchievementRow<Record>], inout AchievementTally, Date) -> Void
    /// Runs before a read: the game's backfill from history, once per boot.
    public let prepare: @Sendable () async -> Void

    public init(catalog: [AchievementDefinition], ledger: AchievementLedger<Record>, identities: PlayerIdentityStore,
                prepare: @escaping @Sendable () async -> Void = {},
                evaluate: @escaping @Sendable ([AchievementRow<Record>], inout AchievementTally, Date) -> Void) {
        self.catalog = catalog
        self.ledger = ledger
        self.identities = identities
        self.prepare = prepare
        self.evaluate = evaluate
    }

    public struct Item: Content, Equatable {
        public let id: String
        public let title: String
        public let detail: String
        public let points: Int
        public let group: String
        public let hidden: Bool
        public let target: Int
        public let progress: Int
        public let earned: Bool
        public let earnedAt: String?
    }
    public struct Board: Content, Equatable {
        public let id: String
        public let score: Int
    }
    public struct Standing: Content {
        public let achievements: [Item]
        public let earnedPoints: Int
        public let totalPoints: Int
        public let leaderboards: [Board]
    }

    public func boot(routes: RoutesBuilder) throws {
        routes.grouped("api", "v1").get("achievements", use: read)
    }

    func read(req: Request) async throws -> Standing {
        guard let key = PlayerKeys.sanitized(try? req.query.get(String.self, at: "key")) else {
            throw Abort(.badRequest, reason: "key is required")
        }
        await prepare()
        return standing(rows: await ledger.rows(forKeys: await identities.keys(sameAs: key)), now: Date())
    }

    /// An unearned hidden achievement goes out with its words and progress removed. The client
    /// never has them, so no client can leak them.
    public func standing(rows: [AchievementRow<Record>], now: Date) -> Standing {
        var tally = AchievementTally(catalog: catalog)
        evaluate(rows, &tally, now)
        let items = catalog.map { a -> Item in
            let at = tally.earnedAt[a.id]
            let secret = a.hidden && at == nil
            return Item(id: a.id, title: secret ? "Hidden" : a.title,
                        detail: secret ? "Keep playing to find this one." : a.detail,
                        points: a.points, group: a.group, hidden: a.hidden, target: secret ? 1 : a.target,
                        progress: secret ? 0 : min(tally.progress[a.id] ?? 0, a.target), earned: at != nil, earnedAt: at)
        }
        return Standing(achievements: items,
                        earnedPoints: items.filter(\.earned).reduce(0) { $0 + $1.points },
                        totalPoints: catalog.reduce(0) { $0 + $1.points },
                        leaderboards: tally.scores.sorted { $0.key < $1.key }.map { Board(id: $0.key, score: $0.value) })
    }
}
