import Foundation
import Vapor

/// The REST surface every game shares: linking devices into one person, "forget me", and the
/// network diagnostics feed. Register it next to the game's own controller:
///
///     try app.register(collection: IdentityRoutes(identities: .shared, linkCodes: .shared) { key in
///         await GameHistoryStore.shared.forget(key: key)
///     })
///
/// History and leaderboard reads stay with the game — their row shapes differ — but the identity
/// half of the leaderboard is `LeaderboardTally`.
public struct IdentityRoutes: RouteCollection {
    public let identities: PlayerIdentityStore
    public let linkCodes: LinkCodeStore
    /// Redacts one key out of the game's history; returns rows changed.
    public let forgetHistory: @Sendable (String) async -> Int

    public init(identities: PlayerIdentityStore, linkCodes: LinkCodeStore, forgetHistory: @escaping @Sendable (String) async -> Int) {
        self.identities = identities
        self.linkCodes = linkCodes
        self.forgetHistory = forgetHistory
    }

    public func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")
        api.delete("history", "mine", use: forgetMe)
        // Three verbs, deliberately small: show a code, redeem a code, take a device back out.
        api.get("link", use: linkStatus)
        api.post("link", "code", use: issueLinkCode)
        api.post("link", "code", "rotate", use: rotateLinkCode)
        api.post("link", "redeem", use: redeemLinkCode)
        api.post("link", "unlink", use: unlinkDevice)
        api.get("diagnostics", use: getDiagnostics)
    }

    // MARK: DTOs

    public struct LinkStatus: Content {
        public let linked: Bool
        /// How many devices are this person, counting the one that asked.
        public let devices: Int
        /// Every key that is this person, the asking one included. The client needs them to
        /// count games played on the OTHER devices as its own: history rows name seats by key,
        /// and a device that only knows its own key found none of them after linking. Only ever
        /// returned to a key that is already one of them.
        public let keys: [String]
        /// The person's permanent link code, once they have one.
        public let code: String?
    }

    public struct LinkCodeRequest: Content { public let key: String }
    public struct LinkCodeResponse: Content {
        public let code: String
        /// 0 for a permanent code. Kept for clients that count it down.
        public let expiresInSeconds: Int
        public let permanent: Bool
    }
    public struct RedeemRequest: Content { public let code: String; public let key: String }
    public struct RedeemResponse: Content {
        public let devices: Int
        /// True when the two were already the same person — pressing link twice is not an error.
        public let alreadyLinked: Bool
    }
    public struct UnlinkRequest: Content { public let key: String }

    // MARK: Handlers

    /// "Forget me": redacts one player's seats out of the history.
    ///
    /// Authenticated by the key itself, which is the only credential this player has — and is
    /// the right shape for it, since holding the key is exactly what it means to be this player.
    /// It never appears in any broadcast state, so it cannot be harvested from the table.
    ///
    /// Every device this person linked goes, not just the one that asked. "Forget me" means the
    /// person; someone clearing their record on the iPad would be startled to find the Mac's
    /// games still on the board. The identity record goes with them, so each device is a
    /// stranger again afterwards.
    func forgetMe(req: Request) async throws -> [String: Int] {
        let key = try requiredKey(try? req.query.get(String.self, at: "key"))
        let keys = await identities.forget(key: key)
        var changed = 0
        for key in keys { changed += await forgetHistory(key) }
        return ["gamesRedacted": changed, "devicesCleared": keys.count]
    }

    func linkStatus(req: Request) async throws -> LinkStatus {
        let key = try requiredKey(try? req.query.get(String.self, at: "key"))
        let identity = await identities.identity(for: key)
        // "Linked" means more than one device; an identity of one exists only to hold a code.
        return LinkStatus(linked: (identity?.keys.count ?? 1) > 1, devices: identity?.keys.count ?? 1,
                          keys: identity?.keys ?? [key], code: identity?.linkCode)
    }

    /// Issued on the device that already has the history; the other device redeems it. The
    /// person's PERMANENT link code — the same on every one of their devices, memorized once.
    /// Anyone who types it joins the record, so it is a password for the record;
    /// `rotateLinkCode` is the reset.
    func issueLinkCode(req: Request) async throws -> LinkCodeResponse {
        let key = try requiredKey(try req.content.decode(LinkCodeRequest.self).key)
        return LinkCodeResponse(code: await identities.permanentCode(for: key), expiresInSeconds: 0, permanent: true)
    }

    func rotateLinkCode(req: Request) async throws -> LinkCodeResponse {
        let key = try requiredKey(try req.content.decode(LinkCodeRequest.self).key)
        return LinkCodeResponse(code: await identities.rotateCode(for: key), expiresInSeconds: 0, permanent: true)
    }

    func redeemLinkCode(req: Request) async throws -> RedeemResponse {
        let body = try req.content.decode(RedeemRequest.self)
        let key = try requiredKey(body.key)
        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // A permanent code first (on the identity); the one-time store is still consulted for
        // clients that have not moved over yet.
        let issuedFor: String
        let permanent: String?
        if let owner = await identities.identity(withCode: code), let first = owner.keys.first {
            issuedFor = first
            permanent = code
        } else if let pending = await linkCodes.redeem(code) {
            issuedFor = pending
            permanent = nil
        } else {
            throw Abort(.notFound, reason: "That code doesn't match any record.")
        }
        guard issuedFor != key else { throw Abort(.badRequest, reason: "That code came from this device.") }
        let outcome = await identities.link(existingKey: issuedFor, newKey: key)
        // The code the person typed stays the record's code, whichever identity the merge kept.
        if let permanent { await identities.adoptCode(permanent, for: key) }
        switch outcome {
        case .alreadyLinked(let identity): return RedeemResponse(devices: identity.keys.count, alreadyLinked: true)
        case .linked(let identity): return RedeemResponse(devices: identity.keys.count, alreadyLinked: false)
        }
    }

    func unlinkDevice(req: Request) async throws -> LinkStatus {
        let key = try requiredKey(try req.content.decode(UnlinkRequest.self).key)
        _ = await identities.unlink(key: key)
        return LinkStatus(linked: false, devices: 1, keys: [key], code: nil)
    }

    /// Recent SLOW socket sends and stretched ping gaps, attributed to the player whose connection
    /// was slow. A healthy game returns an empty list — see `NetDiagnostics`.
    func getDiagnostics(req: Request) async throws -> [NetDiagnostics.Event] {
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 100
        return await NetDiagnostics.shared.recent(limit: max(1, min(limit, 300)))
    }

    private func requiredKey(_ raw: String?) throws -> String {
        guard let key = PlayerKeys.sanitized(raw) else { throw Abort(.badRequest, reason: "key is required") }
        return key
    }
}
