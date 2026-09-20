import Foundation
import Testing
import Vapor
@testable import GameServerKit

// Sockets are not constructible in a unit test, so these exercise the membership and chat
// bookkeeping through join/leave with a socket-free path: `join` stores the socket but nothing
// below touches it until a broadcast, and a lounge with no sockets broadcasts to nobody.

@Test func loungeMergesDevicesAndTracksArrivalOrder() async throws {
    let lounge = Lounge()
    // A WebSocket can't be faked; use the snapshot/people path via reflection-free means:
    // build people through `joinForTesting`, which shares the bookkeeping with `join`.
    let a1 = await lounge.joinForTesting(personId: "ann", name: "Ann")
    _ = await lounge.joinForTesting(personId: "bob", name: "Bob")
    let a2 = await lounge.joinForTesting(personId: "ann", name: "Annie")
    var snap = await lounge.snapshot()
    #expect(snap.people.map(\.name) == ["Annie", "Bob"])   // arrival order, latest name
    #expect(snap.people[0].devices == 2)
    #expect(await lounge.count == 2)

    let line = await lounge.say("  hi all  ", from: a1)
    #expect(line?.text == "hi all" && line?.name == "Ann")   // the sending device's name
    #expect(await lounge.say("", from: a1) == nil)
    #expect(await lounge.say(String(repeating: "x", count: 301), from: a1) == nil)
    snap = await lounge.snapshot()
    #expect(snap.chat.count == 1)
    #expect(snap.people[0].lastActiveAt >= snap.people[0].since)

    await lounge.leave(a1)
    #expect(await lounge.count == 2)          // Ann still here on the other device
    await lounge.leave(a2)
    #expect(await lounge.count == 1)
    #expect(await lounge.snapshot().people.map(\.name) == ["Bob"])
}

@Test func loungeCapsChatHistory() async {
    let lounge = Lounge()
    let id = await lounge.joinForTesting(personId: "p", name: "P")
    for i in 0..<(Lounge.maxChatLines + 5) { _ = await lounge.say("m\(i)", from: id) }
    let chat = await lounge.snapshot().chat
    #expect(chat.count == Lounge.maxChatLines)
    #expect(chat.first?.text == "m5")
}
