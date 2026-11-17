import Foundation
import Testing
import Vapor
import XCTVapor
@testable import GameServerKit

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("gsk-\(name)-\(UUID().uuidString).json")
}

// MARK: Rules

@Test func wordRulesFollowJoesChoice() {
    let rules = SecretWordRules.standard
    #expect(rules.problem(with: "BANANAS") == nil)
    #expect(rules.problem(with: "MAPLE7") == nil)
    #expect(rules.problem(with: "PIZZA") == .tooShort)
    #expect(rules.problem(with: "123456") == .needsLetter)
    #expect(rules.problem(with: "MY WORD") == .badCharacters)
    #expect(rules.problem(with: "CAFÉ12") == .badCharacters)
    #expect(rules.problem(with: String(repeating: "A", count: 21)) == .tooLong)
    #expect(rules.problem(with: "FUCKOFF") == .notAllowed)
    #expect(SecretWordRules.normalize("  bananas ") == "BANANAS")
    #expect(SecretWordRules(requireDigit: true).problem(with: "BANANAS") == .needsDigit)
}

// MARK: Registry

@Test func importMarksCollisionsLocalOnlyAndIsIdempotent() async {
    let r = SecretWordRegistry(fileURL: scratch("words"))
    let a = UUID(), b = UUID(), c = UUID()
    await r.importLocal(game: "swoop", codes: [(a, "BARREL"), (c, "TIGER4")])
    await r.importLocal(game: "quadfecta", codes: [(b, "BARREL")])
    await r.importLocal(game: "quadfecta", codes: [(b, "BARREL")])
    let barrel = await r.entry(word: "BARREL")
    #expect(barrel?.owners == ["swoop": a, "quadfecta": b])
    #expect(barrel?.localOnly == true)
    #expect(await r.entry(word: "TIGER4")?.localOnly == nil)
    #expect(await r.allWords() == ["BARREL", "TIGER4"])
}

@Test func claimRenamesInPlaceSoEveryGameFollows() async {
    let r = SecretWordRegistry(fileURL: scratch("words"))
    let swoop = UUID(), qf = UUID(), stranger = UUID()
    await r.importLocal(game: "swoop", codes: [(swoop, "TIGER4"), (stranger, "MAPLES")])
    #expect(await r.attach(word: "TIGER4", game: "quadfecta", identity: qf) != nil)
    guard case .claimed = await r.claim("BANANAS", game: "swoop", identity: swoop) else {
        Issue.record("should claim"); return
    }
    #expect(await r.entry(word: "TIGER4") == nil)
    #expect(await r.entry(game: "quadfecta", identity: qf)?.word == "BANANAS")
    #expect(await r.claim("MAPLES", game: "quadfecta", identity: qf) == .taken)
}

@Test func localOnlyWordsDoNotCrossGamesAndClaimLeavesThemBehind() async {
    let r = SecretWordRegistry(fileURL: scratch("words"))
    let a = UUID(), b = UUID()
    await r.importLocal(game: "swoop", codes: [(a, "BARREL")])
    await r.importLocal(game: "quadfecta", codes: [(b, "BARREL")])
    #expect(await r.attach(word: "BARREL", game: "other", identity: UUID()) == nil)
    _ = await r.claim("ORCHARDS", game: "swoop", identity: a)
    #expect(await r.entry(word: "BARREL")?.owners == ["quadfecta": b])
    #expect(await r.entry(word: "ORCHARDS")?.owners == ["swoop": a])
}

@Test func releaseKeepsTheWordForTheOtherGame() async {
    let r = SecretWordRegistry(fileURL: scratch("words"))
    let a = UUID(), b = UUID()
    _ = await r.claim("BANANAS", game: "swoop", identity: a)
    _ = await r.attach(word: "BANANAS", game: "quadfecta", identity: b)
    await r.release(game: "swoop", identity: a)
    #expect(await r.entry(word: "BANANAS")?.owners == ["quadfecta": b])
    await r.release(game: "quadfecta", identity: b)
    #expect(await r.entry(word: "BANANAS") == nil)
}

@Test func twoRegistriesOnOneFileSeeEachOthersWrites() async {
    let url = scratch("words")
    let swoop = SecretWordRegistry(fileURL: url), qf = SecretWordRegistry(fileURL: url)
    _ = await swoop.claim("BANANAS", game: "swoop", identity: UUID())
    #expect(await qf.claim("BANANAS", game: "quadfecta", identity: UUID()) == .taken)
}

// MARK: Routes, two games against one shared list

private struct Game {
    let app: Application
    let identities: PlayerIdentityStore
}

private func makeGame(_ name: String, words: URL) async throws -> Game {
    let app = try await Application.make(.testing)
    let identities = PlayerIdentityStore(fileURL: scratch("\(name)-ids"))
    try app.register(collection: IdentityRoutes(identities: identities, linkCodes: LinkCodeStore(),
                                                words: SecretWordRegistry(fileURL: words), game: name) { _ in 0 })
    return Game(app: app, identities: identities)
}

private struct Check: Codable { let word: String; let available: Bool; let yours: Bool; let problem: String? }
private struct Status: Codable { let linked: Bool; let devices: Int; let keys: [String]; let code: String? }

@Test func oneWordWorksInBothGamesAndChangingItKeepsTheRecord() async throws {
    let words = scratch("shared")
    let swoop = try await makeGame("swoop", words: words)
    let qf = try await makeGame("quadfecta", words: words)
    defer { Task { try? await swoop.app.asyncShutdown(); try? await qf.app.asyncShutdown() } }

    // Swoop player on their Mac already has a random code and some history.
    let oldCode = await swoop.identities.permanentCode(for: "swoop-mac-key")
    let swoopRecord = await swoop.identities.identity(for: "swoop-mac-key")!.id

    // Typing: too short, then free.
    try await swoop.app.test(.GET, "api/v1/word/check?word=bana&key=swoop-mac-key") { res async throws in
        let c = try res.content.decode(Check.self)
        #expect(!c.available && c.problem == "tooShort")
    }
    try await swoop.app.test(.GET, "api/v1/word/check?word=bananas&key=swoop-mac-key") { res async throws in
        let c = try res.content.decode(Check.self)
        #expect(c.available && c.word == "BANANAS")
    }
    try await swoop.app.test(.POST, "api/v1/word", beforeRequest: { req async throws in
        try req.content.encode(["key": "swoop-mac-key", "word": "bananas"])
    }) { res async throws in
        #expect(res.status == .ok)
        #expect(try res.content.decode(Status.self).code == "BANANAS")
    }
    // Same record, new word; the old one is gone.
    #expect(await swoop.identities.identity(for: "swoop-mac-key")?.id == swoopRecord)
    #expect(await swoop.identities.identity(withCode: oldCode) == nil)

    // In Quadfecta it now reads as taken for a stranger...
    try await qf.app.test(.GET, "api/v1/word/check?word=BANANAS&key=stranger-qf-key") { res async throws in
        let c = try res.content.decode(Check.self)
        #expect(!c.available && c.problem == "taken")
    }
    // ...and typing it on the person's iPad in Quadfecta makes that the Quadfecta record.
    try await qf.app.test(.POST, "api/v1/link/redeem", beforeRequest: { req async throws in
        try req.content.encode(["key": "qf-ipad-key", "code": "bananas"])
    }) { res async throws in
        #expect(res.status == .ok)
    }
    // A second Quadfecta device joins that same record with the word.
    try await qf.app.test(.POST, "api/v1/link/redeem", beforeRequest: { req async throws in
        try req.content.encode(["key": "qf-phone-key", "code": "BANANAS"])
    }) { res async throws in
        #expect(res.status == .ok)
    }
    #expect(Set(await qf.identities.keys(sameAs: "qf-phone-key")) == ["qf-ipad-key", "qf-phone-key"])

    // Changing the word in Quadfecta renames it in Swoop too, without touching either record.
    try await qf.app.test(.POST, "api/v1/word", beforeRequest: { req async throws in
        try req.content.encode(["key": "qf-phone-key", "word": "ORCHARD9"])
    }) { res async throws in
        #expect(try res.content.decode(Status.self).code == "ORCHARD9")
    }
    try await swoop.app.test(.GET, "api/v1/link?key=swoop-mac-key") { res async throws in
        #expect(try res.content.decode(Status.self).code == "ORCHARD9")
    }
    try await swoop.app.test(.POST, "api/v1/link/redeem", beforeRequest: { req async throws in
        try req.content.encode(["key": "swoop-new-key", "code": "BANANAS"])
    }) { res async throws in
        #expect(res.status == .notFound)
    }
    try await swoop.app.test(.POST, "api/v1/link/redeem", beforeRequest: { req async throws in
        try req.content.encode(["key": "swoop-new-key", "code": "orchard9"])
    }) { res async throws in
        #expect(res.status == .ok)
    }
    #expect(await swoop.identities.identity(for: "swoop-new-key")?.id == swoopRecord)
}
