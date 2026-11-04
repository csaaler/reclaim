import Foundation

/// `FileOperating` backed by `FileManager`. Used only by `CleanupEngine`.
public struct RealFileOperations: FileOperating {
    public struct TrashLocationUnknown: Error, Sendable, CustomStringConvertible {
        public let path: String
        public var description: String { "Moved \(path) to the Trash, but its new location is unknown" }
    }

    public struct ContainsOtherVolume: LocalizedError, Sendable {
        public let path: String
        public init(path: String) { self.path = path }
        public var errorDescription: String? { "Contains another volume" }
    }

    public struct TooLargeToCheck: LocalizedError, Sendable {
        public let path: String
        public init(path: String) { self.path = path }
        public var errorDescription: String? { "Too many items to check that it holds no other volume" }
    }

    private let volumeCheck: @Sendable (String) -> VolumeBoundary.Finding

    public init(volumeCheck: @escaping @Sendable (String) -> VolumeBoundary.Finding = { VolumeBoundary.check($0) }) {
        self.volumeCheck = volumeCheck
    }

    /// Removes the item at `path`. A symlink is removed itself; its destination is not touched.
    /// A folder that holds another volume (a mount point anywhere below it) is refused, as is
    /// one too large to check.
    public func remove(_ path: String) throws {
        switch volumeCheck(path) {
        case .sameVolume: break
        case .otherVolume: throw ContainsOtherVolume(path: path)
        case .tooLarge: throw TooLargeToCheck(path: path)
        }
        try FileManager.default.removeItem(atPath: path)
    }

    public func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        guard let trashed = resulting?.path else { throw TrashLocationUnknown(path: path) }
        return trashed
    }

    public func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Atomic: writes a temporary file and renames it over `path`. Keeps the POSIX permissions
    /// of a file it replaces (an atomic write would otherwise reset them to the default).
    public func write(_ data: Data, to path: String) throws {
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions]
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let permissions {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }
}
