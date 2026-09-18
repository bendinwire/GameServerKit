import Vapor
import Foundation

/// One person's device keys, gathered under a single identity.
///
/// A device key already answers "same player as last time" on ONE machine. It cannot answer it
/// across machines, so the same human playing on the Mac, the iPad and the Windows app is three
/// strangers to the leaderboard. Linking fixes that without accounts: the keys stay where they
/// are, and the server keeps a list saying these belong together.
///
/// Deliberately NOT a key copied from one device to another. A copied key cannot be un-copied, so
/// a code seen over someone's shoulder would be permanent, and the second device's own earlier
/// games would stay orphaned under the key it used to have. An identity owning several keys merges
/// history in both directions and can be taken apart again.
public struct PlayerIdentity: Codable, Content, Equatable, Sendable {
    public let id: UUID
    /// Every device key that is this person. Order is the order they were linked.
    public var keys: [String]
    public let createdAt: String
    /// The person's permanent link code: six characters they memorize once and type on every new
    /// device. Optional: identities written before codes existed have none until one is asked
    /// for, and an Optional is the one shape the synthesized decoder tolerates missing.
    /// (`rotateCode` replaces it; a code seen over a shoulder is a code you retire.)
    public var linkCode: String?

    public init(id: UUID, keys: [String], createdAt: String, linkCode: String?) {
        self.id = id
        self.keys = keys
        self.createdAt = createdAt
        self.linkCode = linkCode
    }
}

/// Game-agnostic. Every game server that has device keys and a leaderboard wants exactly this,
/// so it lives here rather than in any one API.
public actor PlayerIdentityStore {
    /// One JSON object per line, rewritten only when something is unlinked or forgotten. Sits
    /// in the server's working directory beside whatever history file it is read with.
    ///
    /// The path is injectable so a test can be given a scratch file. Without that, every test
    /// run would write the real one in the working directory and the tests would share state
    /// with each other and with a server running from the same folder.
    private let file: JSONLinesFile<PlayerIdentity>
    private var cache: [PlayerIdentity]?

    public init(fileURL: URL = URL(fileURLWithPath: "player_identities.jsonl")) {
        self.file = JSONLinesFile(url: fileURL)
    }

    /// The identity a key belongs to, if it has been linked to anything.
    public func identity(for key: String) -> PlayerIdentity? {
        loadIfNeeded().first { $0.keys.contains(key) }
    }

    /// Every key that is the same person as this one, including the key itself.
    ///
    /// An unlinked key is its own answer rather than an error: everything that reads this treats
    /// a lone device as an identity of one, so nothing has to care whether linking has happened.
    public func keys(sameAs key: String) -> [String] {
        identity(for: key)?.keys ?? [key]
    }

    /// The whole map, for a caller aggregating every row at once (the leaderboard). Returned as
    /// key -> identity id so a caller can group without asking about each key in turn.
    public func identityIdsByKey() -> [String: UUID] {
        var out: [String: UUID] = [:]
        for identity in loadIfNeeded() {
            for key in identity.keys { out[key] = identity.id }
        }
        return out
    }

    /// How many devices each identity owns, keyed by identity id. The leaderboard shows it.
    public func keyCountsByIdentity() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for identity in loadIfNeeded() { out[identity.id] = identity.keys.count }
        return out
    }

    public enum LinkOutcome: Equatable, Sendable {
        /// Already the same person. Not an error: pressing link twice, or re-linking a device
        /// that was already linked, should say so rather than fail.
        case alreadyLinked(PlayerIdentity)
        case linked(PlayerIdentity)
    }

    /// Files `newKey` under `existingKey`'s identity, creating that identity if this is the first
    /// time either device has been linked to anything.
    ///
    /// Both keys may already have identities: someone links their Mac and iPad, then links the
    /// iPad to a Windows box that was itself linked to something. The two identities merge,
    /// oldest first, because that one has the longer history behind it and its id is the one
    /// already written into whatever this server has cached.
    public func link(existingKey: String, newKey: String) -> LinkOutcome {
        var identities = loadIfNeeded()
        let existingIndex = identities.firstIndex { $0.keys.contains(existingKey) }
        let newIndex = identities.firstIndex { $0.keys.contains(newKey) }

        if let existingIndex, existingIndex == newIndex {
            return .alreadyLinked(identities[existingIndex])
        }

        switch (existingIndex, newIndex) {
        case let (.some(a), .some(b)):
            // Two identities becoming one. Keep the older record and fold the newer into it.
            let (keep, drop) = identities[a].createdAt <= identities[b].createdAt ? (a, b) : (b, a)
            let absorbed = identities[drop].keys.filter { !identities[keep].keys.contains($0) }
            identities[keep].keys.append(contentsOf: absorbed)
            if identities[keep].linkCode == nil { identities[keep].linkCode = identities[drop].linkCode }
            let merged = identities[keep]
            identities.remove(at: drop)
            persist(identities)
            return .linked(merged)
        case let (.some(index), .none):
            identities[index].keys.append(newKey)
            let updated = identities[index]
            persist(identities)
            return .linked(updated)
        case let (.none, .some(index)):
            identities[index].keys.append(existingKey)
            let updated = identities[index]
            persist(identities)
            return .linked(updated)
        case (.none, .none):
            let identity = PlayerIdentity(
                id: UUID(),
                keys: [existingKey, newKey],
                createdAt: ISO8601DateFormatter().string(from: Date()),
                linkCode: nil
            )
            identities.append(identity)
            persist(identities)
            return .linked(identity)
        }
    }

    /// Takes one device back out. The identity survives for the rest; an identity down to one
    /// key is dropped entirely, since a list of one is what an unlinked key already means.
    @discardableResult
    public func unlink(key: String) -> Bool {
        var identities = loadIfNeeded()
        guard let index = identities.firstIndex(where: { $0.keys.contains(key) }) else { return false }
        identities[index].keys.removeAll { $0 == key }
        // An identity of one survives if it carries a permanent code. The code is the thing the
        // person memorized, and unlinking a spare device must not retire it.
        if identities[index].keys.isEmpty
            || (identities[index].keys.count < 2 && identities[index].linkCode == nil) {
            identities.remove(at: index)
        }
        persist(identities)
        return true
    }

    /// Forgets the whole person: returns every key that was this identity (so history can be
    /// redacted for all of them) and removes the identity record itself.
    ///
    /// "Clear my record" means the person, not the machine. Someone clearing their record on the
    /// iPad would be very surprised to find the Mac's games still on the leaderboard.
    public func forget(key: String) -> [String] {
        var identities = loadIfNeeded()
        guard let index = identities.firstIndex(where: { $0.keys.contains(key) }) else { return [key] }
        let keys = identities[index].keys
        identities.remove(at: index)
        persist(identities)
        return keys
    }

    // MARK: Permanent link codes

    public static let codeLength = 6

    /// This key's permanent code, minting an identity of one (and a code) if it has neither.
    public func permanentCode(for key: String) -> String {
        var identities = loadIfNeeded()
        if let index = identities.firstIndex(where: { $0.keys.contains(key) }) {
            if let code = identities[index].linkCode { return code }
            let code = freshCode(among: identities)
            identities[index].linkCode = code
            persist(identities)
            return code
        }
        let code = freshCode(among: identities)
        identities.append(PlayerIdentity(
            id: UUID(), keys: [key],
            createdAt: ISO8601DateFormatter().string(from: Date()), linkCode: code
        ))
        persist(identities)
        return code
    }

    /// Retires the current code and issues another. The old one stops working at once.
    public func rotateCode(for key: String) -> String {
        var identities = loadIfNeeded()
        guard let index = identities.firstIndex(where: { $0.keys.contains(key) }) else {
            return permanentCode(for: key)
        }
        let code = freshCode(among: identities)
        identities[index].linkCode = code
        persist(identities)
        return code
    }

    /// Makes `code` the code of the identity holding `key`. Used after a redeem merges two
    /// identities: the merge keeps the OLDER record's code, but the person typed THIS one and
    /// it is the one they memorized, so it wins.
    public func adoptCode(_ code: String, for key: String) {
        var identities = loadIfNeeded()
        guard let index = identities.firstIndex(where: { $0.keys.contains(key) }),
              identities[index].linkCode != code else { return }
        identities[index].linkCode = code
        persist(identities)
    }

    public func identity(withCode code: String) -> PlayerIdentity? {
        let wanted = code.uppercased()
        return loadIfNeeded().first { $0.linkCode == wanted }
    }

    /// A link code is a WORD, not six random characters: it exists to be typed on the next
    /// device from memory, and nobody remembers "ZAAPVG". These are not bank accounts; a
    /// guessable code costs at worst a stranger seeing your win rate. Always six letters, so
    /// every code is the same shape wherever it is shown or typed. Uppercased so it compares
    /// with typed input.
    public static let codeWords: [String] = """
    acorns almond anchor apples arrows badger bagels bamboo banana banjos \
    barley barrel basket beacon beaver bishop bonnet border bottle branch \
    breeze bridge bronze bucket buffet bundle burger butter button cactus \
    camels candle canyon carrot castle cattle celery cellar cheese cherry \
    chisel cinder citrus clover cobalt coffee comets copper cotton cougar \
    coyote cradle crayon dagger dahlia denims desert dinner dollar donkey \
    dragon eagles fabric falcon fiddle flames forest fossil garden garlic \
    geckos ginger goblet gopher grapes gravel guitar hammer harbor helmet \
    hockey hornet iguana indigo island jacket jaguar jersey jungle kernel \
    kettle kitten ladder lagoon laurel lemons lentil lizard llamas locket \
    magnet mantis marble meadow melons meteor mirror mitten monkey mosaic \
    muffin napkin nectar needle noodle nutmeg ocelot olives orange orchid \
    oyster paddle parrot pastry peanut pebble pepper pickle pigeon pillow \
    pirate planet plover pocket pollen poplar potato puddle puffin puzzle \
    quartz rabbit radish raisin ravens ribbon rocket saddle salmon sandal \
    shadow shovel silver socket spider sponge spruce squash string summit \
    sunset tablet teapot timber toffee tomato tulips tundra turnip turtle \
    velvet violet walnut walrus wasabi willow window wizard yogurt zephyr
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { $0.uppercased() }

    private func freshCode(among identities: [PlayerIdentity]) -> String {
        let taken = Set(identities.compactMap(\.linkCode))
        let free = Self.codeWords.filter { !taken.contains($0) }
        if let word = free.randomElement() { return word }
        // Every word is spoken for: more people than the list expected. Fall back to the first
        // five letters of a word plus one digit. Still six characters, still reads as a word
        // ("BARRE7"), and ten times the list before that runs out too.
        var code: String
        repeat {
            code = "\(Self.codeWords.randomElement()!.prefix(5))\(Int.random(in: 0...9))"
        } while taken.contains(code)
        return code
    }

    private func loadIfNeeded() -> [PlayerIdentity] {
        if let cache { return cache }
        let loaded = file.load()
        cache = loaded
        return loaded
    }

    /// Rewrites the file. Unlike a history log there is nothing append-only to preserve here:
    /// an identity is current state, not a record of something that happened, and a link that
    /// has been undone should leave nothing behind.
    private func persist(_ identities: [PlayerIdentity]) {
        cache = identities
        file.rewrite(identities)
    }
}
