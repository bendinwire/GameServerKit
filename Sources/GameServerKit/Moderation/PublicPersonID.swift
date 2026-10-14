import Foundation
import Vapor

/// The id other players see for a person: stable across their linked devices and across tables,
/// so a block or a report follows the person rather than one seat — and a one-way hash, so it
/// can't be turned back into the device key, which is that player's only credential.
public enum PublicPersonID {
    /// The person's identity when their devices are linked, the key itself otherwise.
    public static func of(key: String, identities: PlayerIdentityStore) async -> String {
        let basis = await identities.identity(for: key)?.id.uuidString ?? key
        return hash(basis)
    }

    /// The same id from an `identityIdsByKey()` snapshot, for when a whole history's worth of
    /// seats needs one and an actor hop per seat is waste.
    public static func of(key: String, identityIdsByKey: [String: UUID]) -> String {
        hash(identityIdsByKey[key]?.uuidString ?? key)
    }

    static func hash(_ basis: String) -> String {
        let digest = SHA256.hash(data: Data("person:\(basis)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
