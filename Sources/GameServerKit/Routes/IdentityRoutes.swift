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
    /// The secret-word list shared with the other games, and this game's name in it. Both nil
    /// keeps the old one-game behaviour (and the word routes answer 404).
    public let words: SecretWordRegistry?
    public let game: String?
    public let wordRules: SecretWordRules

    public init(identities: PlayerIdentityStore, linkCodes: LinkCodeStore,
                words: SecretWordRegistry? = nil, game: String? = nil, wordRules: SecretWordRules = .standard,
                forgetHistory: @escaping @Sendable (String) async -> Int) {
        self.identities = identities
        self.linkCodes = linkCodes
        self.words = words
        self.game = game?.lowercased()
        self.wordRules = wordRules
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
        // Choosing your own secret word: a live "is it free?" while typing, and the claim.
        api.get("word", "check", use: checkWord)
        api.post("word", use: claimWord)
        if let words, let game {
            // File this game's existing words in the shared list, so the other game sees them
            // as taken and a word typed there can find its way here.
            let identities = self.identities
            Task {
                await words.importLocal(game: game, codes: await identities.allCodes())
            }
        }
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
    public struct WordClaimRequest: Content { public let key: String; public let word: String }
    public struct WordCheck: Content {
        /// The word as it will be stored (uppercased, trimmed), so the client can show it.
        public let word: String
        public let available: Bool
        /// Already this person's word.
        public let yours: Bool
        /// Why not, when not: tooShort, tooLong, badCharacters, needsLetter, needsDigit,
        /// notAllowed, taken.
        public let problem: String?
        public let message: String?
    }

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
        if let words, let game, let identity = await identities.identity(for: key) {
            await words.release(game: game, identity: identity.id)
        }
        let keys = await identities.forget(key: key)
        var changed = 0
        for key in keys { changed += await forgetHistory(key) }
        return ["gamesRedacted": changed, "devicesCleared": keys.count]
    }

    func linkStatus(req: Request) async throws -> LinkStatus {
        let key = try requiredKey(try? req.query.get(String.self, at: "key"))
        return await status(for: key)
    }

    private func status(for key: String) async -> LinkStatus {
        let identity = await identities.identity(for: key)
        let code: String?
        if let identity { code = await syncedCode(identity) } else { code = nil }
        // "Linked" means more than one device; an identity of one exists only to hold a code.
        return LinkStatus(linked: (identity?.keys.count ?? 1) > 1, devices: identity?.keys.count ?? 1,
                          keys: identity?.keys ?? [key], code: code)
    }

    /// This identity's word, after squaring this game's copy with the shared list: the person may
    /// have picked a new word in the other game since, and that one wins. A word the shared list
    /// has never seen (minted here since startup) is filed in it.
    private func syncedCode(_ identity: PlayerIdentity) async -> String? {
        guard let words, let game else { return identity.linkCode }
        if let entry = await words.entry(game: game, identity: identity.id) {
            if entry.word != identity.linkCode { await identities.setCode(entry.word, forIdentity: identity.id) }
            return entry.word
        }
        if let code = identity.linkCode {
            await words.importLocal(game: game, codes: [(identity.id, code)])
            // Imported, or found held elsewhere and marked local-only; either way it is still ours.
        }
        return identity.linkCode
    }

    private func takenElsewhere() async -> Set<String> {
        await words?.allWords() ?? []
    }

    /// Issued on the device that already has the history; the other device redeems it. The
    /// person's PERMANENT link code — the same on every one of their devices, memorized once.
    /// Anyone who types it joins the record, so it is a password for the record;
    /// `rotateLinkCode` is the reset.
    func issueLinkCode(req: Request) async throws -> LinkCodeResponse {
        let key = try requiredKey(try req.content.decode(LinkCodeRequest.self).key)
        var code = await identities.permanentCode(for: key, avoiding: await takenElsewhere())
        if let identity = await identities.identity(for: key) { code = await syncedCode(identity) ?? code }
        return LinkCodeResponse(code: code, expiresInSeconds: 0, permanent: true)
    }

    /// A new random word. With a shared list it is a rename like any chosen word, so it retires
    /// the old word in every game at once.
    func rotateLinkCode(req: Request) async throws -> LinkCodeResponse {
        let key = try requiredKey(try req.content.decode(LinkCodeRequest.self).key)
        guard let words, let game else {
            return LinkCodeResponse(code: await identities.rotateCode(for: key), expiresInSeconds: 0, permanent: true)
        }
        _ = await identities.permanentCode(for: key, avoiding: await words.allWords())
        guard let identity = await identities.identity(for: key) else { throw Abort(.internalServerError) }
        for _ in 0..<20 {
            let fresh = await identities.unusedCode(avoiding: await words.allWords())
            if case .claimed = await words.claim(fresh, game: game, identity: identity.id) {
                await identities.setCode(fresh, forIdentity: identity.id)
                return LinkCodeResponse(code: fresh, expiresInSeconds: 0, permanent: true)
            }
        }
        throw Abort(.serviceUnavailable, reason: "Couldn't find a free word. Try again.")
    }

    // MARK: Secret words

    /// Live check while the person types. Says why a word won't do, or whether it is free across
    /// every game. Rate-limited per address: it is also a way to ask "is BANANAS somebody's?".
    func checkWord(req: Request) async throws -> WordCheck {
        guard words != nil, game != nil else { throw Abort(.notFound) }
        try await WordAttemptLimiter.shared.allow(req, bucket: "check", perMinute: 120)
        let key = PlayerKeys.sanitized(try? req.query.get(String.self, at: "key"))
        let word = SecretWordRules.normalize((try? req.query.get(String.self, at: "word")) ?? "")
        return await check(word, key: key)
    }

    private func check(_ word: String, key: String?) async -> WordCheck {
        if let problem = wordRules.problem(with: word) {
            return WordCheck(word: word, available: false, yours: false, problem: problem.rawValue,
                             message: wordRules.message(for: problem))
        }
        let mine = key != nil ? await identities.identity(for: key!) : nil
        if let mine, await syncedCode(mine) == word {
            return WordCheck(word: word, available: true, yours: true, problem: nil, message: "That's already your word.")
        }
        let localHolder = await identities.identity(withCode: word)
        let shared = await words?.entry(word: word)
        if (localHolder != nil && localHolder?.id != mine?.id) || shared != nil {
            return WordCheck(word: word, available: false, yours: false, problem: "taken", message: "That word is taken.")
        }
        return WordCheck(word: word, available: true, yours: false, problem: nil, message: nil)
    }

    /// Makes the typed word this person's secret word in every game. Only the word changes: the
    /// record, its devices and its history stay put, and the old word stops working everywhere.
    func claimWord(req: Request) async throws -> LinkStatus {
        guard let words, let game else { throw Abort(.notFound) }
        try await WordAttemptLimiter.shared.allow(req, bucket: "claim", perMinute: 20)
        let body = try req.content.decode(WordClaimRequest.self)
        let key = try requiredKey(body.key)
        let word = SecretWordRules.normalize(body.word)
        let verdict = await check(word, key: key)
        if verdict.yours { return await status(for: key) }
        guard verdict.available else {
            throw Abort(verdict.problem == "taken" ? .conflict : .badRequest, reason: verdict.message ?? "That word won't work.")
        }
        // A device with no record yet gets one here: the word needs something to belong to.
        _ = await identities.permanentCode(for: key, avoiding: await words.allWords())
        guard let identity = await identities.identity(for: key) else { throw Abort(.internalServerError) }
        _ = await syncedCode(identity)
        guard case .claimed = await words.claim(word, game: game, identity: identity.id) else {
            throw Abort(.conflict, reason: "That word is taken.")
        }
        await identities.setCode(word, forIdentity: identity.id)
        return await status(for: key)
    }

    func redeemLinkCode(req: Request) async throws -> RedeemResponse {
        if words != nil { try await WordAttemptLimiter.shared.allow(req, bucket: "redeem", perMinute: 20) }
        let body = try req.content.decode(RedeemRequest.self)
        let key = try requiredKey(body.key)
        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // A permanent code first (on the identity); the one-time store is still consulted for
        // clients that have not moved over yet.
        let issuedFor: String
        let permanent: String?
        // A local holder only counts if the shared list still agrees: a word renamed in the
        // other game must stop working here too.
        var localOwner = await identities.identity(withCode: code)
        if let owner = localOwner, await syncedCode(owner) != code { localOwner = nil }
        if localOwner == nil, let words, let game, let entry = await words.entry(word: code), entry.localOnly != true {
            if let id = entry.owners[game], let owner = await identities.identity(withId: id), !owner.keys.isEmpty {
                // This game already has the person's record; its copy of the word was behind.
                await identities.setCode(code, forIdentity: id)
                localOwner = await identities.identity(withId: id)
            } else {
                // The word was chosen in another game and this is the first time it is typed
                // here: this device's record (new or not) becomes the person's record here.
                _ = await identities.permanentCode(for: key, avoiding: await words.allWords())
                guard let mine = await identities.identity(for: key),
                      await words.attach(word: code, game: game, identity: mine.id) != nil else {
                    throw Abort(.notFound, reason: "That code doesn't match any record.")
                }
                await identities.setCode(code, forIdentity: mine.id)
                return RedeemResponse(devices: mine.keys.count, alreadyLinked: false)
            }
        }
        if let owner = localOwner, let first = owner.keys.first {
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
        // The merge may have kept the other record; make sure the shared list names the survivor.
        if let words, let game, let permanent, let survivor = await identities.identity(for: key),
           await words.entry(game: game, identity: survivor.id)?.word != permanent {
            if let entry = await words.entry(word: permanent), entry.localOnly != true {
                _ = await words.attach(word: permanent, game: game, identity: survivor.id)
            } else {
                await words.importLocal(game: game, codes: [(survivor.id, permanent)])
            }
        }
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

/// Per-address attempt counts for the secret-word routes, in memory. Generous for a person typing
/// (each keystroke is a check) and stingy for anyone walking a dictionary.
actor WordAttemptLimiter {
    static let shared = WordAttemptLimiter()
    private var hits: [String: [Date]] = [:]

    func allow(_ req: Request, bucket: String, perMinute: Int) throws {
        // Behind nginx-proxy the peer is the proxy; the first forwarded address is the player.
        let forwarded = req.headers.first(name: "X-Forwarded-For")?
            .split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let who = "\(bucket):\(forwarded ?? req.remoteAddress?.ipAddress ?? "?")"
        let cutoff = Date().addingTimeInterval(-60)
        var recent = (hits[who] ?? []).filter { $0 > cutoff }
        guard recent.count < perMinute else {
            hits[who] = recent
            throw Abort(.tooManyRequests, reason: "Too many tries. Wait a minute and try again.")
        }
        recent.append(Date())
        hits[who] = recent
        if hits.count > 5000 { hits = hits.filter { $0.value.contains { $0 > cutoff } } }
    }
}
