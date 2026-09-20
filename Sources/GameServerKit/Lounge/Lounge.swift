import Foundation
import Vapor

/// The lobby's front porch: who is idling on the entry screen, and a chat line for them.
///
/// One per game process. Nothing is persisted — it is the conversation happening NOW between
/// people who have the app open and are not at a table; a client drops its lounge socket the
/// moment it sits down, so "here" means idling, and the public-rooms list already says who is
/// playing. People are merged by identity (the Mac and the iPad of one person are one row with a
/// device count), and each row carries when they arrived and when they last said something, so
/// a client can show "quiet for 12m" without the server deciding what idle means.
public actor Lounge {
    public struct Person: Content, Sendable, Equatable {
        /// Stable for the person across their devices (an identity id, or the key, or the socket).
        public let id: String
        public let name: String
        public let since: Date
        public let lastActiveAt: Date
        public let devices: Int
    }

    public struct ChatLine: Content, Sendable, Equatable {
        public let id: Int
        public let personId: String
        public let name: String
        public let text: String
        public let at: Date
    }

    public struct Snapshot: Content, Sendable {
        public let people: [Person]
        public let chat: [ChatLine]
    }

    /// One message shape, server to client. `people` is the full list whenever it changes (it is
    /// small); `line` is one new chat line. A client applies whichever fields are present.
    public struct ServerMessage: Content, Sendable {
        public let type: String
        public var people: [Person]? = nil
        public var chat: [ChatLine]? = nil
        public var line: ChatLine? = nil
        public var message: String? = nil
    }

    public struct ClientMessage: Decodable, Sendable {
        public let type: String
        public var text: String? = nil
    }

    public static let maxChatLines = 100
    public static let maxTextLength = 300
    /// A socket silent for this long has no one behind it — same logic as `PresenceTracker`.
    public static let socketSilenceTimeout: TimeInterval = 45

    private struct Connection {
        /// Nil only for the test seam below.
        let socket: WebSocket?
        let personId: String
        var name: String
        var lastHeardFrom: Date
    }

    private var connections: [UUID: Connection] = [:]
    private var arrivedAt: [String: Date] = [:]
    private var lastActiveAt: [String: Date] = [:]
    private var chat: [ChatLine] = []
    private var nextLineId = 1
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init() {}

    // MARK: Membership

    /// Seats a socket in the lounge. `personId` groups this person's devices.
    public func join(socket: WebSocket, personId: String, name: String) -> UUID {
        seat(socket: socket, personId: personId, name: name)
    }

    /// A member with no socket: `WebSocket` can't be constructed in a unit test.
    func joinForTesting(personId: String, name: String) -> UUID {
        seat(socket: nil, personId: personId, name: name)
    }

    private func seat(socket: WebSocket?, personId: String, name: String) -> UUID {
        let id = UUID()
        let now = Date()
        connections[id] = Connection(socket: socket, personId: personId, name: name, lastHeardFrom: now)
        if arrivedAt[personId] == nil { arrivedAt[personId] = now }
        lastActiveAt[personId] = max(lastActiveAt[personId] ?? now, now)
        return id
    }

    public func leave(_ id: UUID) async {
        guard let gone = connections.removeValue(forKey: id) else { return }
        if !connections.values.contains(where: { $0.personId == gone.personId }) {
            arrivedAt[gone.personId] = nil
            lastActiveAt[gone.personId] = nil
        }
        await broadcastPeople()
    }

    public func noteAlive(_ id: UUID) {
        connections[id]?.lastHeardFrom = Date()
    }

    /// What a socket receives right after joining, and what `GET /lounge` returns.
    public func snapshot() -> Snapshot {
        Snapshot(people: people(), chat: chat)
    }

    public func announceArrival() async {
        await broadcastPeople()
    }

    // MARK: Chat

    /// Returns the line, or nil when the text was empty or too long (the caller answers with an error).
    @discardableResult
    public func say(_ text: String, from id: UUID) async -> ChatLine? {
        guard let conn = connections[id] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxTextLength).contains(trimmed.count) else { return nil }
        let line = ChatLine(id: nextLineId, personId: conn.personId, name: conn.name, text: trimmed, at: Date())
        nextLineId += 1
        chat.append(line)
        if chat.count > Self.maxChatLines { chat.removeFirst(chat.count - Self.maxChatLines) }
        lastActiveAt[conn.personId] = line.at
        await broadcast(ServerMessage(type: "lounge_chat", people: people(), line: line))
        return line
    }

    // MARK: Housekeeping

    /// Drops sockets whose peer stopped talking, so a force-quit client doesn't sit in the list
    /// forever. Run from the same scheduled cleanup as the rooms.
    public func sweep(now: Date = Date()) async {
        let dead = connections.filter { now.timeIntervalSince($0.value.lastHeardFrom) > Self.socketSilenceTimeout }
        for (id, conn) in dead {
            connections[id] = nil
            if let socket = conn.socket { Task { try? await socket.close(code: .goingAway) } }
            if !connections.values.contains(where: { $0.personId == conn.personId }) {
                arrivedAt[conn.personId] = nil
                lastActiveAt[conn.personId] = nil
            }
        }
        if !dead.isEmpty { await broadcastPeople() }
    }

    public var count: Int { Set(connections.values.map(\.personId)).count }

    // MARK: Private

    private func people() -> [Person] {
        var byPerson: [String: (name: String, devices: Int)] = [:]
        for c in connections.values {
            var entry = byPerson[c.personId] ?? (name: c.name, devices: 0)
            entry.devices += 1
            entry.name = c.name
            byPerson[c.personId] = entry
        }
        return byPerson.map { id, entry in
            Person(id: id, name: entry.name, since: arrivedAt[id] ?? Date(),
                   lastActiveAt: lastActiveAt[id] ?? arrivedAt[id] ?? Date(), devices: entry.devices)
        }.sorted { $0.since < $1.since }
    }

    private func broadcastPeople() async {
        await broadcast(ServerMessage(type: "lounge_people", people: people()))
    }

    public func encode(_ message: ServerMessage) -> String {
        (try? encoder.encode(message)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"type":"error","message":"encode"}"#
    }

    private func broadcast(_ message: ServerMessage) async {
        let text = encode(message)
        let outbound = connections.compactMap { id, c in c.socket.map { SocketSends.Outbound(id: id, socket: $0, text: text) } }
        let names = connections.mapValues(\.name)
        await SocketSends.fanOut(outbound, room: "lounge", operation: "lounge") { names[$0] ?? "?" }
    }
}
