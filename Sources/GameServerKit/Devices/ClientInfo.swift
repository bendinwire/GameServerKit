import Foundation
import Vapor

/// What a player is holding, as the client itself reports it — so a bug report can be matched to
/// a platform, an app version and an OS without asking.
///
/// Sent as the `X-Client` header on REST calls and as `?client=` on WebSocket upgrades (browsers
/// cannot set headers on those). The value is `key=value` pairs separated by `;`:
///
///     platform=mac; app=1.3.31 (762); os=macOS 26.0; device=Mac16,10
///     platform=web; app=1.3.31 (7326c6e); os=iOS 18.6; device=Safari; host=discord
///
/// Unknown keys are kept in `extra`. Everything is optional; a client from before this existed
/// simply reports nothing and shows as "unknown".
public struct ClientInfo: Codable, Content, Sendable, Equatable {
    /// mac, ipad, iphone, web, windows — the client's own word for itself.
    public var platform: String?
    /// App version and build, e.g. "1.3.31 (762)"; the web sends version + commit.
    public var app: String?
    /// "macOS 26.0", "iPadOS 26.0", "Windows 11", "iOS 18.6 Safari"…
    public var os: String?
    /// Hardware model or browser: "Mac16,10", "iPad16,3", "Chrome 130".
    public var device: String?
    /// Where the web build is running: browser, discord, tauri.
    public var host: String?
    public var extra: [String: String]?

    public init(platform: String? = nil, app: String? = nil, os: String? = nil, device: String? = nil, host: String? = nil, extra: [String: String]? = nil) {
        self.platform = platform; self.app = app; self.os = os; self.device = device; self.host = host; self.extra = extra
    }

    public static func parse(_ raw: String) -> ClientInfo? {
        var info = ClientInfo()
        var any = false
        for pair in raw.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            any = true
            let value = String(parts[1].prefix(80))
            switch parts[0].lowercased() {
            case "platform": info.platform = value
            case "app": info.app = value
            case "os": info.os = value
            case "device": info.device = value
            case "host": info.host = value
            default:
                if (info.extra?.count ?? 0) < 8 { info.extra = (info.extra ?? [:]).merging([String(parts[0].prefix(24)): value]) { $1 } }
            }
        }
        return any ? info : nil
    }

    /// One line for a table: "iPad · 1.3.31 (762) · iPadOS 26.0 · iPad16,3".
    public var summary: String {
        [platform, app, os, device, host].compactMap { $0 }.joined(separator: " · ")
    }
}

public extension Request {
    /// The client's self-description from the `X-Client` header, or `?client=` for a socket
    /// upgrade. Nil for a client that predates this.
    var clientInfo: ClientInfo? {
        if let header = headers.first(name: "X-Client") { return ClientInfo.parse(header) }
        if let q = query[String.self, at: "client"] { return ClientInfo.parse(q) }
        return nil
    }
}
