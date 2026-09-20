import Foundation

public enum PlayerKeys {
    /// A player key is opaque to the server — it exists only to say "same player as last time" —
    /// so the only thing worth checking is that it is a sane length and not blank. Anything else
    /// is treated as absent, which drops that seat back to being identified by name alone,
    /// exactly as an older client is.
    public static func sanitized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              (8...128).contains(trimmed.count) else { return nil }
        return trimmed
    }
}
