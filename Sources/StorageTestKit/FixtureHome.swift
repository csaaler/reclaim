import Foundation

/// A throwaway home directory for tests. Deleted in `deinit`.
public final class FixtureHome: Sendable {
    /// Real (symlink-resolved) path of the temporary directory.
    public let home: URL

    public init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageTestKit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        home = base.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// Writes a file of `bytes` real bytes, creating parent directories.
    public func file(_ relative: String, bytes: Int = 1024, modified: Date? = nil) throws {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    public func dir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    /// Creates a symlink at `relative` whose destination is `target`, verbatim.
    public func symlink(_ relative: String, to target: String) throws {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// Writes `object` as JSON (sorted keys), creating parent directories.
    public func json(_ relative: String, _ object: Any) throws {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func url(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }
}
