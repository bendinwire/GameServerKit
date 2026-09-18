import Foundation

/// Keeps slurs and obscenities out of player names.
///
/// Names are the one piece of free text every other player is forced to read — it sits on a seat
/// for the whole level, gets spoken by the log ("X guessed Y's tile…"), and outlives the game in
/// the history list. This is a house rule for a table of friends, not moderation at scale: it is
/// deliberately small, checked on the server so every client gets the same answer, and it errs
/// toward letting an odd name through rather than rejecting a real one.
public enum NameFilter {
    /// Rejected wherever they appear, including inside a longer word. Kept SHORT on purpose:
    /// every entry here is a promise that no real name contains it, and that promise is easy to
    /// break — "cunt" is in Scunthorpe, "spic" in suspicious, "anal" in Analiese, "cum" in
    /// Cumberland, "shit" in Shittake. Those all live in the whole-word list instead.
    private static let anywhere: [String] = [
        "nigg", "fagg", "kike", "wetback", "tranny", "molest", "pedophile", "fuck",
        "dickhead", "cocksuck", "motherfuck",
    ]

    /// Rejected as a whole word, with ordinary endings allowed ("retarded", "bitches"). This is
    /// where anything that is a substring of a real name or an ordinary word belongs.
    private static let wholeWord: [String] = [
        "ass", "arse", "hell", "damn", "crap", "tit", "piss", "turd", "shit", "cunt",
        "pussy", "bitch", "whore", "slut", "prick", "twat", "wank", "bollock", "penis",
        "vagina", "anal", "semen", "cum", "rape", "rapist", "retard", "spastic", "chink",
        "spic", "nazi", "hitler", "boob", "wtf", "stfu", "bastard", "douche", "jizz",
    ]

    /// Endings allowed after a whole word, so a list of stems covers the forms people actually
    /// type. "assassin" survives because "assin" is not one of these.
    private static let endings: Set<String> = ["", "s", "es", "ed", "er", "ers", "ing", "y", "ies", "hole", "head"]

    /// Checked against the de-spaced, de-doubled form, which is how anyone actually evades a word
    /// list ("f u c k", "N-I-G-G-E-R", "faaaag"). Necessarily even shorter than `anywhere`: with
    /// the separators gone, every name is one long word, so anything here matches inside surnames
    /// too. These four are worth that.
    /// Checked against the fully collapsed form, where runs of a letter become one — the only
    /// thing that catches "fuuuuck". Just the one word: collapsing turns "nigger" into "niger",
    /// which is a country, and "faggot" into "fagot", which is close enough to the surname Fagan's
    /// neighbourhood to leave alone. Separator evasion ("N-I-G-G-E-R") is handled by the
    /// de-spaced pass instead, which keeps doubled letters and so keeps those words intact.
    private static let stretched: [String] = ["fuck"]

    /// Common letter-for-symbol swaps, so `sh1t` and `f@ck` don't walk straight past a list of
    /// plain words. Applied only for the CHECK — the name is stored exactly as typed.
    private static let deleet: [Character: Character] = [
        "0": "o", "1": "i", "!": "i", "|": "i", "3": "e", "4": "a", "@": "a",
        "5": "s", "$": "s", "7": "t", "+": "t", "8": "b", "9": "g",
    ]

    /// True when `name` is fit to show to the rest of the table.
    public static func isClean(_ name: String) -> Bool {
        reason(name) == nil
    }

    /// Nil when the name is fine, otherwise a message to hand back to the player.
    ///
    /// Two passes on purpose. The first is the name as typed, minus its decoration, which catches
    /// the ordinary cases. The second collapses repeated letters ("fuuuuck") and every separator
    /// ("f.u.c.k", "f u c k"), which is how anyone actually gets around a word list — at the cost
    /// of the whole-word list, which cannot mean anything once the spaces are gone.
    public static func reason(_ name: String) -> String? {
        let plain = normalize(name, mode: .spaced)
        let despaced = normalize(name, mode: .despaced)
        let stretchedName = normalize(name, mode: .collapsed)

        // The de-spaced form keeps doubled letters, so "N-I-G-G-E-R" and "F.A.G.G.O.T" still
        // contain their stems while Nigel and Fagan still do not.
        if anywhere.contains(where: { plain.contains($0) || despaced.contains($0) }) { return rejection }
        if stretched.contains(where: { stretchedName.contains($0) }) { return rejection }

        // Whole-word matching runs on the spaced form only: in the squashed form every name is one
        // long word, and "ass" would then reject "Cassandra".
        for word in plain.split(separator: " ").map(String.init) {
            for stem in wholeWord where word.hasPrefix(stem) {
                if endings.contains(String(word.dropFirst(stem.count))) { return rejection }
            }
        }
        return nil
    }

    private static let rejection = "Pick a different name — that one won't fly at this table."

    private enum Mode {
        /// Letters and single spaces — what the whole-word pass reads.
        case spaced
        /// Separators dropped entirely, doubled letters kept.
        case despaced
        /// Separators dropped AND runs of a letter reduced to one.
        case collapsed
    }

    /// Lowercased, un-leeted, and reduced to letters — with separators and repeats treated
    /// according to `mode`.
    private static func normalize(_ name: String, mode: Mode) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for raw in name.lowercased() {
            let character = deleet[raw] ?? raw
            if character.isLetter {
                if mode == .collapsed, out.last == character { continue }
                out.append(character)
            } else if mode == .spaced, out.last != " " {
                // Any separator — space, dot, underscore, emoji — reads as a word break.
                out.append(" ")
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
