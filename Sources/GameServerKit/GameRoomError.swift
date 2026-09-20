import Foundation
import Vapor

/// The four ways a room refuses an action. Every game's room throws these; the controller maps
/// them to HTTP where it wants a specific status or message, and the `AbortError` conformance
/// covers everything it does not catch — so an uncaught one is a sensible 4xx, never a 500.
public enum GameRoomError: Error, CustomStringConvertible, AbortError {
    case notFound
    case notAuthorized(String)
    case invalidState(String)
    case illegalAction(String)

    public var description: String {
        switch self {
        case .notFound: return "Not found"
        case .notAuthorized(let m), .invalidState(let m), .illegalAction(let m): return m
        }
    }

    public var reason: String { description }

    public var status: HTTPResponseStatus {
        switch self {
        case .notFound: return .notFound
        case .notAuthorized: return .forbidden
        case .invalidState: return .conflict
        case .illegalAction: return .badRequest
        }
    }
}
