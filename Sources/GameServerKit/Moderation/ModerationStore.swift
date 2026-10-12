import Foundation
import Vapor

/// Reports of abusive chat or players, and the people banned from chatting because of them.
///
/// Apple's rule for apps with user-generated content (guideline 1.2) is a filter, a way to report,
/// a way to block, and a developer who acts on reports. The filter is `ChatFilter`; blocking is
/// client-side (it only has to stop the blocker seeing someone); this is the report half and the
/// "act on it" half. Both files sit next to the other JSONL stores in the server's working directory.
public actor ModerationStore {
    public struct Report: Codable, Content, Sendable, Equatable {
        public let id: UUID
        public let at: Date
        /// Who filed it, as a public id — never the key.
        public let reporterPersonId: String
        public let reporterName: String?
        public let personId: String
        public let name: String
        /// The reported message, when the report was about one line rather than the player.
        public let text: String?
        /// Where it happened: "lounge" or "room:ABCD".
        public let context: String?
        public let reason: String
        public let details: String?
        public let game: String?
    }

    public struct Ban: Codable, Content, Sendable, Equatable {
        public let personId: String
        public let name: String?
        public let at: Date
        public let note: String?
    }

    public static let reasons = ["harassment", "hate", "sexual", "spam", "cheating", "other"]

    private let reportsFile: JSONLinesFile<Report>
    private let bansFile: JSONLinesFile<Ban>
    private var reports: [Report]?
    private var bans: [String: Ban]?

    public init(reportsURL: URL = URL(fileURLWithPath: "moderation_reports.jsonl"),
                bansURL: URL = URL(fileURLWithPath: "moderation_bans.jsonl")) {
        reportsFile = JSONLinesFile(url: reportsURL)
        bansFile = JSONLinesFile(url: bansURL)
    }

    // MARK: Reports

    public func file(_ report: Report) {
        loadReports()
        reports?.append(report)
        reportsFile.append(report)
    }

    /// Newest first.
    public func recentReports(limit: Int = 200) -> [Report] {
        loadReports()
        return Array((reports ?? []).suffix(limit).reversed())
    }

    // MARK: Bans

    public func isBanned(_ personId: String?) -> Bool {
        guard let personId else { return false }
        loadBans()
        return bans?[personId] != nil
    }

    public func ban(personId: String, name: String?, note: String?) -> Ban {
        loadBans()
        let ban = Ban(personId: personId, name: name, at: Date(), note: note)
        bans?[personId] = ban
        persistBans()
        return ban
    }

    @discardableResult
    public func unban(personId: String) -> Bool {
        loadBans()
        guard bans?.removeValue(forKey: personId) != nil else { return false }
        persistBans()
        return true
    }

    public func allBans() -> [Ban] {
        loadBans()
        return (bans ?? [:]).values.sorted { $0.at > $1.at }
    }

    // MARK: Private

    private func loadReports() {
        if reports == nil { reports = reportsFile.load() }
    }

    private func loadBans() {
        if bans == nil { bans = Dictionary(bansFile.load().map { ($0.personId, $0) }, uniquingKeysWith: { _, b in b }) }
    }

    private func persistBans() {
        bansFile.rewrite((bans ?? [:]).values.sorted { $0.at < $1.at })
    }
}

