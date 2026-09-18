import Foundation

/// Rooms keyed by something outside the game: a chat channel, a calendar invite, a Discord
/// activity instance. "Give me the room for this key, creating it if there is none."
///
/// The value stored is the creation **Task**, not the finished result, and that is the whole
/// point. Two people arriving at the same moment must not end up at two different tables, and
/// the window between "no room for this key" and "room recorded under this key" spans an
/// `await`, during which the owning actor will happily service the second caller. Storing the
/// Task closes the window, because inserting it happens synchronously, before any suspension.
public actor ExternalKeyCreations<Created: Sendable> {
    private var creations: [String: Task<Created, Never>] = [:]
    private var keyByCode: [String: String] = [:]

    public init() {}

    /// - Parameters:
    ///   - code: how to read the room code back out of a creation result, so a reaped room
    ///     takes its key with it.
    ///   - stillExists: whether an earlier creation's room is still live.
    ///   - create: makes the room. Everything the first caller needs (seating the host, say)
    ///     happens INSIDE it, so a racing caller gets the result only once it is whole.
    /// - Returns: the result and whether this call was the one that created it.
    public func findOrCreate(
        key: String,
        code: @escaping @Sendable (Created) -> String,
        stillExists: (Created) async -> Bool,
        create: @escaping @Sendable () async -> Created
    ) async -> (result: Created, created: Bool) {
        if let inFlight = creations[key] {
            let existing = await inFlight.value
            if await stillExists(existing) { return (existing, false) }
            // Reaped by the GC, or ended. The key outlives it, so make a fresh one.
            creations[key] = nil
            keyByCode[code(existing)] = nil
        }
        let task = Task<Created, Never> { await create() }
        creations[key] = task
        let made = await task.value
        keyByCode[code(made)] = key
        return (made, true)
    }

    /// Drops any mapping pointing at `code`, so the tables can't outgrow the rooms they describe.
    public func forget(code: String) {
        guard let key = keyByCode.removeValue(forKey: code) else { return }
        creations[key] = nil
    }
}
