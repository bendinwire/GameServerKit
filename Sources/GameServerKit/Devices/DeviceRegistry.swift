import Foundation
import Vapor

/// One row per player key: the last client it reported, when, and the last table it sat at.
public struct DeviceRecord: Codable, Content, Sendable {
    public let key: String
    public var name: String
    public var client: ClientInfo?
    public var lastSeenAt: Date
    public var lastRoomCode: String?
    public var firstSeenAt: Date
}

/// Who plays on what. Persisted as JSON lines (rewritten whole; it is small) so the list survives
/// a restart. Keys are never exposed in full by `PlayersRoutes` — only enough to tell two rows
/// apart.
public actor DeviceRegistry {
    private let file: JSONLinesFile<DeviceRecord>
    private var records: [String: DeviceRecord]?

    public init(fileURL: URL = URL(fileURLWithPath: "devices.jsonl")) {
        file = JSONLinesFile(url: fileURL)
    }

    /// Called wherever a request carries a player key: create/join/takeover, and the lounge.
    /// A request with no client info still bumps last-seen and the name.
    public func note(key: String, name: String?, client: ClientInfo?, roomCode: String? = nil, now: Date = Date()) {
        var all = load()
        var rec = all[key] ?? DeviceRecord(key: key, name: name ?? "", client: nil, lastSeenAt: now, lastRoomCode: nil, firstSeenAt: now)
        if let name, !name.isEmpty { rec.name = name }
        if let client { rec.client = client }
        if let roomCode { rec.lastRoomCode = roomCode }
        rec.lastSeenAt = now
        all[key] = rec
        records = all
        file.rewrite(all.values.sorted { $0.lastSeenAt > $1.lastSeenAt })
    }

    public func all() -> [DeviceRecord] {
        load().values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    public func record(for key: String) -> DeviceRecord? { load()[key] }

    private func load() -> [String: DeviceRecord] {
        if let records { return records }
        let loaded = Dictionary(file.load().map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.lastSeenAt > b.lastSeenAt ? a : b })
        records = loaded
        return loaded
    }
}
