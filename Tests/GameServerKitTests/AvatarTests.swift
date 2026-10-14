import Foundation
import Testing
@testable import GameServerKit

@Test func avatarStoreKeepsTheLatestPickAcrossRestarts() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    let store = AvatarStore(fileURL: url)
    await store.set("🦊", for: "p1")
    await store.set("👽", for: "p1")
    await store.set("🐸", for: "p2")
    await store.set(nil, for: "p2")
    let reopened = AvatarStore(fileURL: url)
    #expect(await reopened.avatar(for: "p1") == "👽")
    #expect(await reopened.avatar(for: "p2") == nil)
    #expect(Avatars.isValid("💩") && !Avatars.isValid("🍆") && Set(Avatars.all).count == Avatars.all.count)
}

@Test func loungeRowsAndLinesCarryTheAvatar() async {
    let lounge = Lounge()
    let id = await lounge.joinForTesting(personId: "p", name: "Pat", avatar: "🦄")
    #expect(await lounge.snapshot().people.first?.avatar == "🦄")
    #expect(await lounge.say("hi", from: id)?.avatar == "🦄")
}
