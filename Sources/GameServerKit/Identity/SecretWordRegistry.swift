import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One secret word, and the record it unlocks in each game.
///
/// A person's word is the same in every game they play, but their device keys are not (each game
/// stores its own key) and neither are their identity records (each server keeps its own file).
/// So the word is the one thing that ties the games together: it names this person's identity in
/// Swoop AND in Quadfecta, and typing it in either game joins that game's record.
public struct SecretWordEntry: Codable, Equatable, Sendable {
    /// Uppercased, letters and digits only.
    public var word: String
    /// Game name ("swoop", "quadfecta") to that game's `PlayerIdentity.id`.
    public var owners: [String: UUID]
    /// Set when two games each handed out the same random word to two different people before
    /// the games shared a list. Each keeps working in its own game, but neither can be carried to
    /// the other game: there is no telling which of the two people typed it. Optional so an
    /// entry written without it decodes.
    public var localOnly: Bool?
    public var updatedAt: String

    public init(word: String, owners: [String: UUID], localOnly: Bool? = nil, updatedAt: String) {
        self.word = word
        self.owners = owners
        self.localOnly = localOnly
        self.updatedAt = updatedAt
    }
}

/// What a typed word may look like when a player picks their own. Random words the server hands
/// out (BARREL, TIGER4) predate these rules and are not held to them.
public struct SecretWordRules: Sendable {
    public var minLength: Int
    public var maxLength: Int
    /// Off by Joe's call (2026-11-17): any word of six or more, like BANANAS. Turning it on
    /// would make a dictionary word a stranger might try (PIZZAS) into one they won't (PIZZA42).
    public var requireDigit: Bool

    public init(minLength: Int = 6, maxLength: Int = 20, requireDigit: Bool = false) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.requireDigit = requireDigit
    }

    public static let standard = SecretWordRules()

    public enum Problem: String, Codable, Sendable {
        case tooShort, tooLong, badCharacters, needsDigit, needsLetter, notAllowed
    }

    /// Uppercased with surrounding space gone, so "maple7 " and "MAPLE7" are one word.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Nil when a normalized word is fit to claim.
    public func problem(with word: String) -> Problem? {
        guard word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return .badCharacters }
        if word.count < minLength { return .tooShort }
        if word.count > maxLength { return .tooLong }
        if !word.contains(where: \.isLetter) { return .needsLetter }
        if requireDigit, !word.contains(where: \.isNumber) { return .needsDigit }
        // Nobody else ever sees it, but it is on the person's own screen and in support emails.
        if !NameFilter.isClean(word) { return .notAllowed }
        return nil
    }

    public func message(for problem: Problem) -> String {
        switch problem {
        case .tooShort: return "Use at least \(minLength) letters."
        case .tooLong: return "Keep it to \(maxLength) characters or fewer."
        case .badCharacters: return "Letters and numbers only."
        case .needsDigit: return "Add at least one number, like MAPLE7."
        case .needsLetter: return "Use some letters too."
        case .notAllowed: return "Pick a different word."
        }
    }
}

/// The list of secret words shared by every game on this machine.
///
/// A plain JSON file both servers read and write, locked with flock(2) for each change. No cache:
/// the other game may have written since we last looked, and the file is a few kilobytes.
/// Swoop and Quadfecta run as two processes on the same host, so a file is all the "shared
/// service" this needs.
public actor SecretWordRegistry {
    public let url: URL
    private let lockURL: URL

    /// `SECRET_WORDS_FILE` wins, so a test or a second host can point elsewhere. Production uses
    /// one folder outside either app's own so neither deploy owns it; a dev machine without that
    /// folder gets a file in the working directory (one game only, which is all it runs).
    public static func defaultURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["SECRET_WORDS_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sharedFolder, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: sharedFolder).appendingPathComponent("secret_words.json")
        }
        return URL(fileURLWithPath: "secret_words.json")
    }

    public static let sharedFolder = "/opt/flexgames-shared"

    public init(fileURL: URL = SecretWordRegistry.defaultURL()) {
        self.url = fileURL
        self.lockURL = fileURL.appendingPathExtension("lock")
    }

    // MARK: Reads

    public func entry(word: String) -> SecretWordEntry? {
        read().first { $0.word == word }
    }

    /// The entry that names this game's identity, if it has one.
    public func entry(game: String, identity: UUID) -> SecretWordEntry? {
        read().first { $0.owners[game] == identity }
    }

    public func allWords() -> Set<String> {
        Set(read().map(\.word))
    }

    // MARK: Writes

    /// Brings a game's existing words into the shared list: run once at startup. Idempotent.
    /// A word another game already holds for an identity this game cannot vouch for becomes
    /// `localOnly`: both holders keep it in their own game, neither can carry it across.
    public func importLocal(game: String, codes: [(identity: UUID, word: String)]) {
        mutate { entries in
            for (identity, word) in codes {
                // Already the word this identity is filed under: nothing to do.
                if entries.contains(where: { $0.word == word && $0.owners[game] == identity }) { continue }
                // This identity is filed under another word already (a word chosen in this game
                // or the other one, which this game's own copy hasn't caught up with). The shared
                // list wins; the caller syncs the local copy from it.
                if entries.contains(where: { $0.owners[game] == identity }) { continue }
                if let i = entries.firstIndex(where: { $0.word == word }) {
                    if entries[i].owners[game] == nil {
                        entries[i].owners[game] = identity
                        entries[i].localOnly = true
                        entries[i].updatedAt = Self.now()
                    }
                    // A different identity of THIS game under the same word cannot happen (the
                    // local store keeps them unique); ignore rather than guess.
                } else {
                    entries.append(SecretWordEntry(word: word, owners: [game: identity], updatedAt: Self.now()))
                }
            }
        }
    }

    public enum ClaimOutcome: Equatable, Sendable {
        case claimed(SecretWordEntry)
        /// Someone else holds it, in this game or another one.
        case taken
    }

    /// Makes `word` this person's word. If they already have one, it is renamed in place, so the
    /// record it names in every OTHER game moves to the new word too and the old word stops
    /// working everywhere at once.
    public func claim(_ word: String, game: String, identity: UUID) -> ClaimOutcome {
        var outcome = ClaimOutcome.taken
        mutate { entries in
            let mine = entries.firstIndex { $0.owners[game] == identity }
            if let holder = entries.firstIndex(where: { $0.word == word }) {
                guard holder == mine else { return }
                outcome = .claimed(entries[holder])
                return
            }
            if let mine {
                if entries[mine].localOnly == true {
                    // The old word was shared by accident with a stranger in another game; the
                    // stranger keeps it, and this person leaves with a word of their own.
                    entries[mine].owners[game] = nil
                    if entries[mine].owners.isEmpty { entries.remove(at: mine) }
                    let fresh = SecretWordEntry(word: word, owners: [game: identity], updatedAt: Self.now())
                    entries.append(fresh)
                    outcome = .claimed(fresh)
                } else {
                    entries[mine].word = word
                    entries[mine].updatedAt = Self.now()
                    outcome = .claimed(entries[mine])
                }
            } else {
                let fresh = SecretWordEntry(word: word, owners: [game: identity], updatedAt: Self.now())
                entries.append(fresh)
                outcome = .claimed(fresh)
            }
        }
        return outcome
    }

    /// Files this game's `identity` under a word another game already owns: the person typed
    /// their word into a game they have not used it in yet. Any word this identity had in this
    /// game is given up. Nil when the word is unknown or `localOnly`.
    public func attach(word: String, game: String, identity: UUID) -> SecretWordEntry? {
        var result: SecretWordEntry?
        mutate { entries in
            guard let target = entries.firstIndex(where: { $0.word == word }),
                  entries[target].localOnly != true else { return }
            if entries[target].owners[game] == identity { result = entries[target]; return }
            // Whoever this game had filed under the word before (an identity since emptied by
            // "forget me", say) loses it: the word's owner is the person holding it now.
            entries[target].owners[game] = identity
            entries[target].updatedAt = Self.now()
            result = entries[target]
            for i in entries.indices.reversed() where i != target && entries[i].owners[game] == identity {
                entries[i].owners[game] = nil
                if entries[i].owners.isEmpty { entries.remove(at: i) }
            }
        }
        return result
    }

    /// This game's identity is gone ("forget me"). The word survives for the other games.
    public func release(game: String, identity: UUID) {
        mutate { entries in
            for i in entries.indices.reversed() where entries[i].owners[game] == identity {
                entries[i].owners[game] = nil
                if entries[i].owners.isEmpty { entries.remove(at: i) }
            }
        }
    }

    // MARK: File

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func read() -> [SecretWordEntry] {
        withLock(exclusive: false) { load() }
    }

    private func load() -> [SecretWordEntry] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SecretWordEntry].self, from: data)) ?? []
    }

    /// Read, change and write back under one exclusive lock, so the two servers never interleave.
    private func mutate(_ change: (inout [SecretWordEntry]) -> Void) {
        withLock(exclusive: true) {
            var entries = load()
            let before = entries
            change(&entries)
            guard entries != before else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(entries) else { return }
            let temp = url.appendingPathExtension("rewrite")
            do {
                try data.write(to: temp)
            } catch {
                PersistenceHealth.shared.failed(url, "write the replacement for", error)
                return
            }
            if rename(temp.path, url.path) == 0 {
                PersistenceHealth.shared.succeeded(url)
            } else {
                PersistenceHealth.shared.failed(url, "rename the replacement over", POSIXFailure(code: errno))
            }
        }
    }

    private func withLock<T>(exclusive: Bool, _ body: () -> T) -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o664)
        guard fd >= 0 else { return body() }
        defer { close(fd) }
        _ = flock(fd, exclusive ? LOCK_EX : LOCK_SH)
        defer { _ = flock(fd, LOCK_UN) }
        return body()
    }
}
