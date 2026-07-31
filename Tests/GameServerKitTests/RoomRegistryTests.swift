import Foundation
import Testing
@testable import GameServerKit

private actor TestRoom: GameRoom {
    nonisolated let code: String
    private var connected = false
    private var activity = Date()
    private var publicFlag = false

    init(code: String) { self.code = code }

    var hasAnyConnection: Bool { connected }
    var lastActivityAt: Date { activity }
    var isPublic: Bool { publicFlag }

    func setConnected(_ value: Bool) { connected = value }
    func setActivity(_ date: Date) { activity = date }
    func setPublic(_ value: Bool) { publicFlag = value }
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

@Test func roomsAreNotPublicByDefault() async throws {
    let registry = RoomRegistry<TestRoom>()
    _ = await registry.createRoom { code in TestRoom(code: code) }
    let publicRooms = await registry.publicRooms()
    #expect(publicRooms.isEmpty)
}

@Test func publicRoomsReturnsOnlyFlaggedRooms() async throws {
    let registry = RoomRegistry<TestRoom>()
    let publicRoom = await registry.createRoom { code in TestRoom(code: code) }
    await publicRoom.setPublic(true)
    _ = await registry.createRoom { code in TestRoom(code: code) }
    let publicRooms = await registry.publicRooms()
    #expect(publicRooms.map(\.code) == [publicRoom.code])
}
