import Foundation

public struct LogEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let title: String
    /// The action as performed (a 🔴 `.delete` is logged as the `.trash` it became).
    public let action: CleanupAction
    public let risk: RiskLevel
    public let outcome: StepOutcome

    public init(id: UUID, date: Date, title: String, action: CleanupAction, risk: RiskLevel, outcome: StepOutcome) {
        self.id = id
        self.date = date
        self.title = title
        self.action = action
        self.risk = risk
        self.outcome = outcome
    }
}

/// Append-only JSON Lines log of every cleanup step. The only scan-related state that is persisted.
public struct CleanupLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Reclaim/cleanup-log.jsonl`. Never written by tests.
    public static let `default` = CleanupLog(
        fileURL: URL.applicationSupportDirectory
            .appendingPathComponent("Reclaim", isDirectory: true)
            .appendingPathComponent("cleanup-log.jsonl")
    )

    /// Appends one line, creating the file and its directory if needed.
    public func append(_ entry: LogEntry) throws {
        var line = try Self.encoder.encode(entry)
        line.append(0x0A)
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All entries, oldest first. A missing file is an empty log. Lines that fail to decode
    /// (e.g. a torn final write) are skipped so one bad line does not hide the history.
    public func readAll() throws -> [LogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(LogEntry.self, from: Data($0)) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder { JSONDecoder() }
}
