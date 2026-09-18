import Foundation
import Testing
@testable import GameServerKit

private func scratchStore() -> PlayerIdentityStore {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gsk-identities-\(UUID().uuidString).jsonl")
    return PlayerIdentityStore(fileURL: path)
}

@Test func unlinkedKeyIsItsOwnIdentityOfOne() async {
    let s = scratchStore()
    #expect(await s.keys(sameAs: "device-a") == ["device-a"])
    #expect(await s.identity(for: "device-a") == nil)
}

@Test func linkingMergesAndUnlinkingSplits() async {
    let s = scratchStore()
    guard case .linked(let identity) = await s.link(existingKey: "mac", newKey: "ipad") else {
        Issue.record("first link should create an identity"); return
    }
    #expect(identity.keys.count == 2)
    _ = await s.link(existingKey: "win", newKey: "web")
    _ = await s.link(existingKey: "ipad", newKey: "win")
    #expect(Set(await s.keys(sameAs: "web")) == ["mac", "ipad", "win", "web"])
    guard case .alreadyLinked = await s.link(existingKey: "web", newKey: "mac") else {
        Issue.record("expected alreadyLinked"); return
    }
    await s.unlink(key: "web")
    #expect(Set(await s.keys(sameAs: "mac")) == ["mac", "ipad", "win"])
    #expect(await s.keyCountsByIdentity().values.first == 3)
}

@Test func forgetReturnsEveryDeviceAndPersistsAcrossReload() async {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gsk-identities-\(UUID().uuidString).jsonl")
    let s = PlayerIdentityStore(fileURL: path)
    _ = await s.link(existingKey: "a", newKey: "b")
    let code = await s.permanentCode(for: "a")
    #expect(code.count == 6)
    let reloaded = PlayerIdentityStore(fileURL: path)
    #expect(await reloaded.identity(withCode: code)?.keys == ["a", "b"])
    #expect(Set(await reloaded.forget(key: "b")) == ["a", "b"])
    #expect(await reloaded.identity(for: "a") == nil)
}

@Test func linkCodesAreSingleUseAndReissueRetires() async {
    let codes = LinkCodeStore()
    let first = await codes.issue(for: "mac")
    #expect(first.code.count == 4)
    let second = await codes.issue(for: "mac")
    #expect(await codes.redeem(first.code) == nil)
    #expect(await codes.redeem(second.code) == "mac")
    #expect(await codes.redeem(second.code) == nil)
}

@Test func nameFilterAndNormalization() {
    #expect(NameFilter.isClean("Cassandra"))
    #expect(NameFilter.isClean("Scunthorpe"))
    #expect(!NameFilter.isClean("f u c k"))
    #expect(!NameFilter.isClean("sh1thead"))
    #expect(PlayerNames.match("Chris ", "chris"))
    #expect(!PlayerNames.match("Chris", "Christa"))
}

@Test func jsonLinesSkipsBadRowsAndRewritesAtomically() throws {
    struct Row: Codable, Equatable { let n: Int }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gsk-\(UUID().uuidString).jsonl")
    let file = JSONLinesFile<Row>(url: url)
    file.append(Row(n: 1))
    file.append(Row(n: 2))
    try "garbage\n".write(to: url, atomically: false, encoding: .utf8)
    file.append(Row(n: 3))
    #expect(file.load() == [Row(n: 3)])
    file.rewrite([Row(n: 4), Row(n: 5)])
    #expect(file.load() == [Row(n: 4), Row(n: 5)])
    #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("rewrite").path))
}
