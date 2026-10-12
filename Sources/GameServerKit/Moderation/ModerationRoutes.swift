import Foundation
import Vapor

/// `POST /api/v1/reports` — a player reports another player or one of their chat lines.
///   Body: `{key, personId, name, text?, context?, reason, details?}`. The key authenticates the
///   reporter (and is turned into their public id before anything is stored).
///
/// Admin, behind `Authorization: Bearer $<adminTokenEnv>` (fails closed when unset):
/// `GET /api/v1/admin/reports?limit=`, `GET /api/v1/admin/bans`,
/// `POST /api/v1/admin/bans {personId, name?, note?}`, `DELETE /api/v1/admin/bans/:personId`.
///
/// When `MODERATION_NOTIFY_URL` is set, each report is also POSTed there as plain text (an
/// ntfy.sh topic works as-is), so a report is seen within the day rather than when someone
/// remembers to look. When `MODERATION_NOTIFY_EMAIL` is set, each report is also emailed there
/// through `msmtp` (see `email(to:subject:body:logger:)`); the two are independent.
public struct ModerationRoutes: RouteCollection, Sendable {
    public let store: ModerationStore
    public let identities: PlayerIdentityStore
    /// Shown in the notification and stored on the report, e.g. "Swoop".
    public let game: String
    public let adminTokenEnv: String

    public init(store: ModerationStore, identities: PlayerIdentityStore, game: String, adminTokenEnv: String) {
        self.store = store
        self.identities = identities
        self.game = game
        self.adminTokenEnv = adminTokenEnv
    }

    public struct ReportRequest: Content {
        public let key: String
        public let personId: String
        public let name: String
        public var text: String?
        public var context: String?
        public let reason: String
        public var details: String?
    }

    public struct BanRequest: Content {
        public let personId: String
        public var name: String?
        public var note: String?
    }

    public func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1")
        api.post("reports", use: fileReport)
        let admin = api.grouped("admin").grouped(AdminTokenAuth(envName: adminTokenEnv))
        admin.get("reports", use: listReports)
        admin.get("bans", use: listBans)
        admin.post("bans", use: addBan)
        admin.delete("bans", ":personId", use: removeBan)
    }

    func fileReport(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(ReportRequest.self)
        guard let key = PlayerKeys.sanitized(body.key) else { throw Abort(.badRequest, reason: "key is required") }
        let personId = body.personId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(personId.count) else { throw Abort(.badRequest, reason: "personId is required") }
        let reason = ModerationStore.reasons.contains(body.reason) ? body.reason : "other"
        let reporter = await PublicPersonID.of(key: key, identities: identities)
        guard reporter != personId else { throw Abort(.badRequest, reason: "You can't report yourself.") }
        let report = ModerationStore.Report(
            id: UUID(), at: Date(), reporterPersonId: reporter, reporterName: nil,
            personId: personId, name: String(body.name.prefix(40)),
            text: body.text.map { String($0.prefix(400)) }, context: body.context.map { String($0.prefix(40)) },
            reason: reason, details: body.details.map { String($0.prefix(1000)) }, game: game)
        await store.file(report)
        req.logger.warning("moderation report \(report.id): \(reason) against \(report.name) [\(personId)] in \(report.context ?? "?")")
        await notify(report, req: req)
        return .noContent
    }

    func listReports(req: Request) async throws -> [ModerationStore.Report] {
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 200
        return await store.recentReports(limit: max(1, min(limit, 1000)))
    }

    func listBans(req: Request) async throws -> [ModerationStore.Ban] {
        await store.allBans()
    }

    func addBan(req: Request) async throws -> ModerationStore.Ban {
        let body = try req.content.decode(BanRequest.self)
        return await store.ban(personId: body.personId, name: body.name, note: body.note)
    }

    func removeBan(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("personId") else { throw Abort(.badRequest) }
        return await store.unban(personId: id) ? .noContent : .notFound
    }

    private func notify(_ report: ModerationStore.Report, req: Request) async {
        var lines = ["\(game) report: \(report.reason) — \(report.name) [\(report.personId)]"]
        if let context = report.context { lines.append("where: \(context)") }
        if let text = report.text { lines.append("said: \(text)") }
        if let details = report.details, !details.isEmpty { lines.append("details: \(details)") }
        let body = lines.joined(separator: "\n")
        // Email goes through msmtp, not ntfy: ntfy.sh refuses to email for an anonymous publisher
        // (error 40053), which is what 1.8.1's `Email` header ran into.
        if let to = Environment.get("MODERATION_NOTIFY_EMAIL"), !to.isEmpty {
            Self.email(to: to, subject: "\(game) player report", body: body, logger: req.logger)
        }
        guard let raw = Environment.get("MODERATION_NOTIFY_URL"), let url = URL(string: raw) else { return }
        _ = try? await req.client.post(URI(string: url.absoluteString)) { out in
            out.headers.replaceOrAdd(name: "Title", value: "\(game) player report")
            out.body = ByteBuffer(string: body)
        }
    }

    /// Hands a plain-text message to `msmtp -t`, which reads the recipient from the headers. The
    /// recipient and subject come from the environment and from code, never from a player; a
    /// player's text only ever lands in the body, below the blank line, where it can't add a
    /// header. Fire and forget: the report is already stored, and a mail problem must not fail the
    /// request. msmtp reads `/etc/msmtprc`, because a unit with `ProtectHome=true` can't see a
    /// per-user `~/.msmtprc`.
    static func email(to: String, subject: String, body: String, logger: Logger) {
        let candidates = ["/usr/bin/msmtp", "/usr/local/bin/msmtp"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            logger.warning("MODERATION_NOTIFY_EMAIL is set but msmtp is not installed")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-t"]
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            logger.warning("moderation email: could not start msmtp: \(error)")
            return
        }
        let message = "To: \(to)\nSubject: \(subject)\nContent-Type: text/plain; charset=utf-8\n\n\(body)\n"
        input.fileHandleForWriting.write(Data(message.utf8))
        try? input.fileHandleForWriting.close()
        Task.detached {
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.warning("moderation email: msmtp exited \(process.terminationStatus)")
            }
        }
    }
}

/// Bearer-token gate for admin routes, read from the named environment variable. Fails closed:
/// an unset variable rejects everything rather than letting everything through.
public struct AdminTokenAuth: AsyncMiddleware {
    public let envName: String
    public init(envName: String) { self.envName = envName }

    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let expected = Environment.get(envName), !expected.isEmpty else {
            throw Abort(.forbidden, reason: "admin token not configured")
        }
        guard let bearer = req.headers.bearerAuthorization, bearer.token == expected else {
            throw Abort(.unauthorized, reason: "admin token required")
        }
        return try await next.respond(to: req)
    }
}
