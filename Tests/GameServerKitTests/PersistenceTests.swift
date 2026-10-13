import Foundation
import Testing
@testable import GameServerKit

private struct Line: Codable, Equatable { let n: Int }

private func scratchFile(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gsk-persistence-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

@Test func appendCreatesThenAppendsWithoutTruncating() {
    let url = scratchFile("rows.jsonl")
    let file = JSONLinesFile<Line>(url: url)
    file.append(Line(n: 1))
    file.append(Line(n: 2))
    file.append(Line(n: 3))
    #expect(file.load() == [Line(n: 1), Line(n: 2), Line(n: 3)])
    #expect(!PersistenceHealth.shared.status.contains("rows.jsonl"))
}

/// The 2026-09-23 failure, reproduced: the file exists but the service can't write it. The append
/// must be reported (not swallowed), must leave the file exactly as it was, and the report must
/// clear once the file is writable again.
@Test func unwritableFileIsReportedAndLeftIntact() throws {
    let url = scratchFile("locked_history.jsonl")
    let file = JSONLinesFile<Line>(url: url)
    file.append(Line(n: 1))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

    // Root ignores file modes, so the failure can't be provoked there; nothing to assert.
    guard !FileManager.default.isWritableFile(atPath: url.path) else { return }

    file.append(Line(n: 2))
    #expect(PersistenceHealth.shared.status.contains("locked_history.jsonl"))
    #expect(file.load() == [Line(n: 1)])

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    file.append(Line(n: 3))
    #expect(!PersistenceHealth.shared.status.contains("locked_history.jsonl"))
    #expect(file.load() == [Line(n: 1), Line(n: 3)])
}

@Test func failedRewriteIsReported() throws {
    let url = scratchFile("rewrite_me.jsonl")
    let file = JSONLinesFile<Line>(url: url)
    file.append(Line(n: 1))
    // A read-only directory: the temp file can't be created, so the rewrite can't happen.
    let dir = url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    guard !FileManager.default.isWritableFile(atPath: dir.path) else { return }

    file.rewrite([Line(n: 9)])
    #expect(PersistenceHealth.shared.status.contains("rewrite_me.jsonl"))
    #expect(file.load() == [Line(n: 1)])
}
