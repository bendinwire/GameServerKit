import Foundation
import Testing
@testable import GameServerKit

@Test func clientInfoParsesPairsAndIgnoresJunk() {
    let c = ClientInfo.parse("platform=ipad; app=1.3.31 (762); os=iPadOS 26.0; device=iPad16,3; weird=x; =empty; noequals")
    #expect(c?.platform == "ipad" && c?.app == "1.3.31 (762)" && c?.device == "iPad16,3")
    #expect(c?.extra == ["weird": "x"])
    #expect(c?.summary == "ipad · 1.3.31 (762) · iPadOS 26.0 · iPad16,3")
    #expect(ClientInfo.parse("") == nil)
    #expect(ClientInfo.parse("garbage") == nil)
}

@Test func deviceRegistryKeepsLastSeenPerKeyAcrossReload() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gsk-devices-\(UUID().uuidString).jsonl")
    let reg = DeviceRegistry(fileURL: url)
    let t0 = Date(timeIntervalSince1970: 1_000)
    await reg.note(key: "k-mac-000001", name: "Joe", client: ClientInfo.parse("platform=mac; app=1.3.31 (762)"), roomCode: "ABCD", now: t0)
    await reg.note(key: "k-ipad-00001", name: "Joe", client: ClientInfo.parse("platform=ipad"), now: t0.addingTimeInterval(10))
    // A later request with no client info bumps the clock but keeps what was known.
    await reg.note(key: "k-mac-000001", name: "Joseph", client: nil, now: t0.addingTimeInterval(20))
    let all = await DeviceRegistry(fileURL: url).all()
    #expect(all.map(\.key) == ["k-mac-000001", "k-ipad-00001"])
    #expect(all[0].name == "Joseph" && all[0].client?.platform == "mac" && all[0].lastRoomCode == "ABCD")
    #expect(all[0].firstSeenAt == t0)
}
