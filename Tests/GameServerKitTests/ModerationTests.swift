import Foundation
import Testing
@testable import GameServerKit

@Test func publicPersonIdIsStableHashedAndFollowsLinkedDevices() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let identities = PlayerIdentityStore(fileURL: dir.appendingPathComponent("ids.jsonl"))
    let mac = "a".padding(toLength: 32, withPad: "a", startingAt: 0)
    let ipad = "b".padding(toLength: 32, withPad: "b", startingAt: 0)
    let before = await PublicPersonID.of(key: mac, identities: identities)
    #expect(before == (await PublicPersonID.of(key: mac, identities: identities)))
    #expect(!before.contains(mac) && before.count == 24)
    _ = await identities.link(existingKey: mac, newKey: ipad)
    let linkedMac = await PublicPersonID.of(key: mac, identities: identities)
    #expect(linkedMac == (await PublicPersonID.of(key: ipad, identities: identities)))
}

@Test func moderationStoreKeepsReportsAndBansAcrossRestarts() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let reportsURL = dir.appendingPathComponent("r.jsonl"), bansURL = dir.appendingPathComponent("b.jsonl")
    let store = ModerationStore(reportsURL: reportsURL, bansURL: bansURL)
    await store.file(.init(id: UUID(), at: Date(), reporterPersonId: "me", reporterName: nil, personId: "them",
                           name: "Troll", text: "rude", context: "lounge", reason: "harassment", details: nil, game: "Test"))
    _ = await store.ban(personId: "them", name: "Troll", note: nil)
    #expect(await store.isBanned("them"))
    #expect(!(await store.isBanned("me")))

    let reopened = ModerationStore(reportsURL: reportsURL, bansURL: bansURL)
    #expect(await reopened.recentReports().map(\.name) == ["Troll"])
    #expect(await reopened.isBanned("them"))
    #expect(await reopened.unban(personId: "them"))
    #expect(!(await ModerationStore(reportsURL: reportsURL, bansURL: bansURL).isBanned("them")))
}
