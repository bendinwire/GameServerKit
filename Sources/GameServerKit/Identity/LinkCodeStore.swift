import Foundation

/// The short-lived codes that link two devices.
///
/// In memory only, and that is the right call: a code is worth something for ten minutes and
/// surviving a restart is not a feature. An unredeemed code outliving the process it was shown
/// in is a credential nobody is watching any more.
public actor LinkCodeStore {
    /// Four characters, in the room-code alphabet: no 0/O/1/I, because these get read aloud
    /// across a room exactly like a room code does.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let length = 4
    public static let lifetime: TimeInterval = 600

    private struct Pending {
        let key: String
        let expires: Date
    }
    private var codes: [String: Pending] = [:]

    public init() {}

    /// Issues a code for the device that already has the history. Any code that device was
    /// previously given is dropped: two live codes for one device means one of them is a
    /// forgotten credential.
    public func issue(for key: String) -> (code: String, expires: Date) {
        sweep()
        codes = codes.filter { $0.value.key != key }
        var code: String
        repeat {
            code = String((0..<Self.length).map { _ in Self.alphabet.randomElement()! })
        } while codes[code] != nil
        let expires = Date().addingTimeInterval(Self.lifetime)
        codes[code] = Pending(key: key, expires: expires)
        return (code, expires)
    }

    /// Single use: redeeming consumes the code whether or not the link that follows changes
    /// anything, so a code read over a shoulder is worth one attempt at most.
    public func redeem(_ code: String) -> String? {
        sweep()
        guard let pending = codes.removeValue(forKey: code.uppercased()) else { return nil }
        return pending.key
    }

    private func sweep() {
        let now = Date()
        codes = codes.filter { $0.value.expires > now }
    }
}
