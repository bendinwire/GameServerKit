import Foundation

/// Masks profanity and strips links in chat, server-side, so every client (app, web, Windows,
/// Discord) shows the same cleaned line.
///
/// Masks rather than rejects, like most games with chat: the message still arrives, the offending
/// word reads `****`. A rejected message just gets retyped with a misspelling. Shares the word
/// lists and the leet/spacing/stretching tricks with `NameFilter`, minus the mildest words
/// (`chatAllowed`): a name has to suit every table forever, a chat line is one person's moment.
public enum ChatFilter {
    /// Fine in chat even though a name may not use them.
    static let chatAllowed: Set<String> = ["hell", "damn", "crap", "wtf", "stfu"]

    /// The text with offending words masked (same length, `*`) and links replaced by "[link]".
    public static func clean(_ text: String) -> String {
        let delinked = stripLinks(text)
        var chars = Array(delinked)
        let tokens = tokenize(chars)

        // One word at a time: "sh1t" -> "****", "fuuuck!" -> "******!".
        for t in tokens where isProfane(String(chars[t.core])) {
            for i in t.core { chars[i] = "*" }
        }
        // Spelled out to dodge the list: "f u c k", "f.u.c.k". Runs of single-letter tokens are
        // read as one word; the whole run is masked.
        var run: [Token] = []
        func flush() {
            defer { run.removeAll() }
            guard run.count >= 3 else { return }
            let joined = String(run.map { chars[$0.core.lowerBound] })
            if isProfane(joined) { for t in run { chars[t.core.lowerBound] = "*" } }
        }
        for (n, t) in tokens.enumerated() {
            if t.core.count == 1 {
                // Only a short separator may sit between the letters ("f u c k", "f-u-c-k").
                if let prev = run.last, n > 0, t.range.lowerBound - prev.range.upperBound > 2 { flush() }
                run.append(t)
            } else {
                flush()
            }
        }
        flush()
        return String(chars)
    }

    /// True when a single word (any case, leet, stretched) is one the filter masks.
    static func isProfane(_ word: String) -> Bool {
        let plain = NameFilter.normalize(word, mode: .despaced)
        guard !plain.isEmpty else { return false }
        if NameFilter.anywhere.contains(where: { plain.contains($0) }) { return true }
        let collapsed = NameFilter.normalize(word, mode: .collapsed)
        if NameFilter.stretched.contains(where: { collapsed.contains($0) }) { return true }
        for stem in NameFilter.wholeWord where !chatAllowed.contains(stem) && plain.hasPrefix(stem) {
            if NameFilter.endings.contains(String(plain.dropFirst(stem.count))) { return true }
        }
        return false
    }

    // MARK: Pieces

    /// A run of word characters (letters, digits, leet symbols) and the part of it to check:
    /// trailing punctuation ("shit!!") is not part of the word, but inner symbols ("sh!t") are.
    struct Token { var range: Range<Int>; var core: Range<Int> }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || NameFilter.deleet[c] != nil
    }

    static func tokenize(_ chars: [Character]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            guard isWordChar(chars[i]) else { i += 1; continue }
            let start = i
            while i < chars.count, isWordChar(chars[i]) { i += 1 }
            var end = i
            while end > start + 1, !(chars[end - 1].isLetter || chars[end - 1].isNumber) { end -= 1 }
            out.append(Token(range: start..<i, core: start..<end))
        }
        return out
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?://|www\.)\S+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|gg|co|xyz|ly|me|tv|app|dev|ru|cn|info|biz|link|click|site|online|shop)\b(?:/\S*)?"#)

    /// Links are spam and phishing more often than not in a game lobby; none of the games need them.
    static func stripLinks(_ text: String) -> String {
        let ns = text as NSString
        return linkPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "[link]")
    }
}
