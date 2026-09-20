import Foundation

/// The identity-aware half of a leaderboard: which rows count, who each seat belongs to, and
/// what to call them. What is being scored — win rate, levels, average points — is the game's,
/// supplied as `Stat` and folded in per seat.
///
/// Grouping is by IDENTITY where the key has been linked, and by the key itself otherwise, so
/// an unlinked device is simply an identity of one and nothing special-cases it. Names are
/// never grouped on: a name is free text anyone can type, which is the whole reason keys exist.
/// Bots are skipped, and so is a redacted seat: the person asked to be forgotten, and a row of
/// "Former player" is exactly the ranking they asked not to have.
public enum LeaderboardTally {
    /// Below this a win rate is noise — two games at 100% cannot stand above forty at 80%.
    public static let minimumGames = 5

    public struct Seat {
        public let name: String
        public let key: String?
        public let isBot: Bool
        public init(name: String, key: String?, isBot: Bool) {
            self.name = name; self.key = key; self.isBot = isBot
        }
    }

    public struct Person<Stat> {
        /// The name this person used most. Most-recent was wrong on a shared device: a family
        /// iPad where "ben" played fifteen games and a guest played three as "Tornado" ranked as
        /// a second Tornado. The latest name still breaks a tie.
        public let name: String
        public let games: Int
        /// How many devices are linked into this person. 1 means an unlinked device.
        public let devices: Int
        /// True on the row belonging to the key that asked. Decided by the SERVER: a client
        /// cannot recognize its own row otherwise, and the alternative — publishing an id per row
        /// for clients to match on — would put an identifier for every player in a public response.
        public let you: Bool
        public var qualified: Bool { games >= minimumGames }
        public let stat: Stat
    }

    public struct Result<Stat> {
        public let people: [Person<Stat>]
        public let gamesCounted: Int
        /// Games that could not be attributed to anybody: every row played before device keys
        /// existed, and any seat played from a client too old to send one. Reported rather than
        /// hidden, because a board that silently drops half the history looks like one that is
        /// simply wrong.
        public let gamesUnattributed: Int
    }

    private struct Tally<Stat> {
        var nameCounts: [String: Int] = [:]
        var latestName = ""
        var games = 0
        var devices = 1
        var stat: Stat
    }

    /// - Parameters:
    ///   - seats: the seats in a row, in seat order; `fold` is called with the same index.
    ///   - fold: adds one seat's outcome to that person's running stat.
    public static func build<Row, Stat>(
        rows: [Row],
        seats: (Row) -> [Seat],
        redactedName: String,
        identityIdsByKey: [String: UUID],
        keysPerIdentity: [UUID: Int],
        askingKey: String?,
        initial: Stat,
        fold: (inout Stat, Row, Int) -> Void
    ) -> Result<Stat> {
        var tallies: [String: Tally<Stat>] = [:]
        var counted = 0, unattributed = 0

        for row in rows {
            let all = seats(row)
            let counting = all.indices.filter { !all[$0].isBot && all[$0].key != nil && all[$0].name != redactedName }
            if counting.isEmpty { unattributed += 1; continue }
            counted += 1
            for i in counting {
                let seat = all[i]
                let identity = identityIdsByKey[seat.key!]
                let group = identity?.uuidString ?? seat.key!
                var t = tallies[group] ?? Tally(stat: initial)
                t.nameCounts[seat.name, default: 0] += 1
                t.latestName = seat.name
                t.games += 1
                t.devices = identity.flatMap { keysPerIdentity[$0] } ?? 1
                fold(&t.stat, row, i)
                tallies[group] = t
            }
        }

        let myGroup = askingKey.map { identityIdsByKey[$0]?.uuidString ?? $0 }
        let people = tallies.map { group, t -> Person<Stat> in
            let name = t.nameCounts.max { a, b in
                a.value != b.value ? a.value < b.value : (a.key != t.latestName && b.key == t.latestName)
            }?.key ?? t.latestName
            return Person(name: name, games: t.games, devices: t.devices, you: group == myGroup, stat: t.stat)
        }
        return Result(people: people, gamesCounted: counted, gamesUnattributed: unattributed)
    }
}
