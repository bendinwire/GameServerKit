import Foundation
import Testing
@testable import GameServerKit

private struct Row: HistoryRow, Equatable {
    struct Seat: Codable, Equatable { var name: String; var key: String?; var isBot: Bool; var won: Bool }
    var seats: [Seat]

    mutating func redact(key: String, as redactedName: String) -> Bool {
        var changed = false
        for i in seats.indices where seats[i].key == key {
            seats[i].name = redactedName
            seats[i].key = nil
            changed = true
        }
        return changed
    }
}

private func scratchLog() -> HistoryLog<Row> {
    HistoryLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("gsk-history-\(UUID().uuidString).jsonl"))
}

@Test func historyLogAppendsRecentAndForgets() {
    let log = scratchLog()
    log.append(Row(seats: [.init(name: "Ann", key: "k-ann-0001", isBot: false, won: true)]))
    log.append(Row(seats: [.init(name: "Ann", key: "k-ann-0001", isBot: false, won: false),
                           .init(name: "Bob", key: "k-bob-0001", isBot: false, won: true)]))
    #expect(log.allRows.count == 2)
    #expect(log.recent(limit: 1).first?.seats.count == 2)
    #expect(log.forget(key: "k-ann-0001") == 2)
    #expect(log.forget(key: "k-ann-0001") == 0)
    // Survives a reload from disk, and Bob's seat is untouched.
    let reloaded = HistoryLog<Row>(url: log.url)
    #expect(reloaded.allRows[1].seats[0].name == HistoryLog<Row>.redactedName)
    #expect(reloaded.allRows[1].seats[1].name == "Bob")
}

@Test func leaderboardGroupsByIdentityAndSkipsBotsAndRedacted() {
    let id = UUID()
    let rows = [
        Row(seats: [.init(name: "ann", key: "mac", isBot: false, won: true), .init(name: "Bot", key: nil, isBot: true, won: false)]),
        Row(seats: [.init(name: "Ann", key: "ipad", isBot: false, won: false)]),
        Row(seats: [.init(name: "ann", key: "mac", isBot: false, won: true)]),
        Row(seats: [.init(name: "Former player", key: nil, isBot: false, won: true)]),
    ]
    let result = LeaderboardTally.build(
        rows: rows, seats: { $0.seats.map { LeaderboardTally.Seat(name: $0.name, key: $0.key, isBot: $0.isBot) } },
        redactedName: "Former player", identityIdsByKey: ["mac": id, "ipad": id], keysPerIdentity: [id: 2],
        askingKey: "ipad", initial: 0
    ) { wins, row, i in if row.seats[i].won { wins += 1 } }
    #expect(result.gamesCounted == 3)
    #expect(result.gamesUnattributed == 1)
    #expect(result.people.count == 1)
    let ann = result.people[0]
    #expect(ann.name == "ann")      // used most, not most recent
    #expect(ann.games == 3)
    #expect(ann.stat == 2)
    #expect(ann.devices == 2)
    #expect(ann.you)
    #expect(!ann.qualified)
}

@Test func playerTokensAreUrlSafe() {
    for _ in 0..<50 {
        let t = PlayerToken.generate()
        #expect(t.count == 32)
        #expect(t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Test func gameRoomErrorMapsToStatus() {
    #expect(GameRoomError.notFound.status == .notFound)
    #expect(GameRoomError.illegalAction("x").status == .badRequest)
    #expect(GameRoomError.invalidState("x").reason == "x")
}
