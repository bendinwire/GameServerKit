import Vapor
import NIOCore

/// CORS boilerplate every game server needs, so a browser-less native client can hit it
/// from anywhere without maintaining an origin allowlist.
public func configureGameCORS(
    _ app: Application,
    methods: [HTTPMethod] = [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH]
) {
    let configuration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: methods,
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
    )
    app.middleware.use(CORSMiddleware(configuration: configuration), at: .beginning)
}

public extension EventLoopGroup {
    /// Runs `cleanup` on a fixed interval for as long as the app is up. Wraps the two
    /// `scheduleRepeated(Async)Task` call shapes Vapor apps end up hand-writing identically
    /// for room GC.
    func scheduleRoomCleanup(
        initialDelay: TimeAmount = .minutes(30),
        interval: TimeAmount = .minutes(30),
        cleanup: @escaping @Sendable () async -> Void
    ) {
        let loop = self.next()
        loop.scheduleRepeatedAsyncTask(initialDelay: initialDelay, delay: interval) { _ -> EventLoopFuture<Void> in
            let promise = loop.makePromise(of: Void.self)
            promise.completeWithTask { await cleanup() }
            return promise.futureResult
        }
    }
}
