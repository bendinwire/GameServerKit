import Foundation

/// One JSON object per line, on disk, in the server's working directory.
///
/// The persistence story for every game server here is "no database". Rooms live in memory;
/// the few things that must outlive a restart (finished games, linked identities) go to a flat
/// file like this. Low write volume, read back in full, good enough.
///
/// Rows that fail to decode are skipped, not fatal: files are append-only across versions, so
/// an old line the current type cannot read must not take the newer lines down with it. Types
/// stored here should make every field added later Optional for the same reason.
public struct JSONLinesFile<Row: Codable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Every decodable row, in file order (oldest first).
    public func load() -> [Row] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var rows: [Row] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let row = try? decoder.decode(Row.self, from: lineData) else { continue }
            rows.append(row)
        }
        return rows
    }

    /// Adds one row to the end of the file, creating it if needed.
    public func append(_ row: Row) {
        guard let data = try? JSONEncoder().encode(row), let line = String(data: data, encoding: .utf8),
              let lineData = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        } else {
            try? lineData.write(to: url)
        }
    }

    /// Replaces the whole file. Written to a temp file and moved into place so a crash mid-write
    /// cannot leave a half-file where the data used to be.
    public func rewrite(_ rows: [Row]) {
        let encoder = JSONEncoder()
        let lines = rows.compactMap { row -> String? in
            guard let data = try? encoder.encode(row) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let temp = url.appendingPathExtension("rewrite")
        guard (try? text.write(to: temp, atomically: true, encoding: .utf8)) != nil else { return }
        // POSIX rename, not `FileManager.replaceItemAt`: on Linux that call deleted the original
        // and left the `.rewrite` file behind, so the next restart started with nothing.
        // rename(2) is atomic and overwrites in place.
        _ = rename(temp.path, url.path)
    }
}
