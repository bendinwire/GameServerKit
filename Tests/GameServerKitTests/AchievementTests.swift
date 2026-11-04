import XCTest
@testable import GameServerKit

final class AchievementTests: XCTestCase {
    struct Record: Codable, Sendable { var won: Bool }
    typealias Row = AchievementRow<Record>

    private let catalog = [
        AchievementDefinition(id: "first", title: "First", detail: "Win", points: 10, group: "Start"),
        AchievementDefinition(id: "ten", title: "Ten", detail: "Win 10", points: 20, group: "Career", target: 10),
        AchievementDefinition(id: "secret", title: "Secret", detail: "Lose", points: 5, group: "Fun", hidden: true),
    ]

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ach-\(UUID().uuidString).jsonl")
    }

    private func routes(_ ledger: AchievementLedger<Record>) -> AchievementRoutes<Record> {
        AchievementRoutes(catalog: catalog, ledger: ledger, identities: PlayerIdentityStore(fileURL: tempFile())) { rows, tally, _ in
            var wins = 0
            for row in rows {
                if row.record.won { wins += 1 }
                tally.earn("first", if: row.record.won, at: row.at)
                tally.set("ten", wins, at: row.at)
                tally.earn("secret", if: !row.record.won, at: row.at)
            }
            tally.setScore("wins", wins)
        }
    }

    func testRowsSurviveARestartAndAreNotAddedTwice() async {
        let url = tempFile()
        let ledger = AchievementLedger<Record>(fileURL: url)
        let added = await ledger.append(Row(gameId: "g1", key: "a", at: "2026-01-01T00:00:00Z", record: Record(won: true)))
        let repeated = await ledger.append(Row(gameId: "g1", key: "a", at: "2026-01-01T00:00:00Z", record: Record(won: true)))
        XCTAssertTrue(added)
        XCTAssertFalse(repeated)
        let reloaded = await AchievementLedger<Record>(fileURL: url).rows(forKeys: ["a"])
        XCTAssertEqual(reloaded.count, 1)
    }

    func testRowsMergeAcrossKeysOldestFirst() async {
        let ledger = AchievementLedger<Record>(fileURL: tempFile())
        await ledger.append(Row(gameId: "g2", key: "b", at: "2026-01-02T00:00:00Z", record: Record(won: true)))
        await ledger.append(Row(gameId: "g1", key: "a", at: "2026-01-01T00:00:00Z", record: Record(won: false)))
        await ledger.append(Row(gameId: "g3", key: "c", at: "2026-01-03T00:00:00Z", record: Record(won: false)))
        let rows = await ledger.rows(forKeys: ["a", "b"])
        XCTAssertEqual(rows.map(\.gameId), ["g1", "g2"])
    }

    func testForgetRemovesOnlyThatKey() async {
        let url = tempFile()
        let ledger = AchievementLedger<Record>(fileURL: url)
        await ledger.append(Row(gameId: "g1", key: "a", at: "t", record: Record(won: true)))
        await ledger.append(Row(gameId: "g1", key: "b", at: "t", record: Record(won: true)))
        let removed = await ledger.forget(key: "a")
        XCTAssertEqual(removed, 1)
        let a = await AchievementLedger<Record>(fileURL: url).rows(forKeys: ["a"])
        let b = await AchievementLedger<Record>(fileURL: url).rows(forKeys: ["b"])
        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(b.count, 1)
    }

    func testStandingEarnsTracksProgressAndKeepsSecrets() async {
        let r = routes(AchievementLedger<Record>(fileURL: tempFile()))
        let won = r.standing(rows: [Row(gameId: "g", key: "a", at: "t1", record: Record(won: true))], now: Date())
        let first = won.achievements[0], ten = won.achievements[1], secret = won.achievements[2]
        XCTAssertTrue(first.earned)
        XCTAssertEqual(first.earnedAt, "t1")
        XCTAssertEqual(ten.progress, 1)
        XCTAssertFalse(ten.earned)
        XCTAssertEqual(secret.title, "Hidden")
        XCTAssertEqual(won.earnedPoints, 10)
        XCTAssertEqual(won.totalPoints, 35)
        XCTAssertEqual(won.leaderboards, [.init(id: "wins", score: 1)])

        let lost = r.standing(rows: [Row(gameId: "g", key: "a", at: "t1", record: Record(won: false))], now: Date())
        XCTAssertEqual(lost.achievements[2].title, "Secret")
        XCTAssertTrue(lost.achievements[2].earned)
    }

    func testEarnedDateIsWhenTheTargetWasFirstReached() {
        var tally = AchievementTally(catalog: catalog)
        for n in 1...12 { tally.set("ten", n, at: "t\(n)") }
        tally.set("ten", 1, at: "t13")
        XCTAssertEqual(tally.earnedAt["ten"], "t10")
        XCTAssertEqual(tally.progress["ten"], 12)
    }
}
