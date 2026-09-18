import Foundation

public enum PlayerNames {
    /// Lowercased alphanumerics only. The same person types themselves in differently between
    /// sessions and devices ("Chris", "chris", "Chris " from an autocomplete), and none of that
    /// should decide whether they can get back into a game they're already seated in.
    public static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Two typed names that mean the same seat.
    public static func match(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }
}
