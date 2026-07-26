import Foundation
import Testing
@testable import GameServerKit

private actor TestRoom: GameRoom {
    nonisolated let code: String
    private var connected = false
    private var activity = Date()

    init(code: String) { self.code = code }

    var hasAnyConnection: Bool { connected }
    var lastActivityAt: Date { activity }

    func setConnected(_ value: Bool) { connected = value }
    func setActivity(_ date: Date) { activity = date }
}

@Test func createAndFetchRoom() async throws {
    let registry = RoomRegistry<TestRoom>()
    let room = await registry.createRoom { code in TestRoom(code: code) }
    let fetched = await registry.room(for: room.code)
    #expect(fetched != nil)
}

@Test func cleanupDropsStaleDisconnectedRooms() async throws {
    let registry = RoomRegistry<TestRoom>(staleAfter: 0)
    let room = await registry.createRoom { code in TestRoom(code: code) }
    await room.setActivity(Date(timeIntervalSinceNow: -10))
    await registry.cleanupStaleRooms()
    let fetched = await registry.room(for: room.code)
    #expect(fetched == nil)
}

@Test func cleanupKeepsRoomsWithConnections() async throws {
    let registry = RoomRegistry<TestRoom>(staleAfter: 0)
    let room = await registry.createRoom { code in TestRoom(code: code) }
    await room.setConnected(true)
    await room.setActivity(Date(timeIntervalSinceNow: -10))
    await registry.cleanupStaleRooms()
    let fetched = await registry.room(for: room.code)
    #expect(fetched != nil)
}
