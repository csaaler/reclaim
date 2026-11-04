import Darwin
import Foundation

/// Answers whether a folder about to be removed reaches into another volume (a mounted disk
/// image, network share or external drive below it). Removing such a folder would delete files
/// on that volume, so `RealFileOperations.remove` refuses it.
public enum VolumeBoundary {
    public struct Entry: Sendable, Equatable {
        public let device: UInt64
        public let isDirectory: Bool
        public init(device: UInt64, isDirectory: Bool) {
            self.device = device
            self.isDirectory = isDirectory
        }
    }

    public enum Finding: Sendable, Equatable {
        case sameVolume
        /// The first entry found whose device differs from the root's.
        case otherVolume(String)
        /// More than `maxEntries` entries; the tree was not fully checked.
        case tooLarge
    }

    public static let defaultMaxEntries = 5_000_000

    /// One iterative walk of the tree under `root`, using `lstat` so symlinks are never followed.
    /// It does not descend into an entry on another device; finding one is the answer. Entries
    /// that vanish or folders that cannot be listed are passed over (the removal itself fails on
    /// anything it cannot read). A root that is not a directory is `.sameVolume`.
    public static func check(
        _ root: String,
        maxEntries: Int = defaultMaxEntries,
        lstat: (String) -> Entry? = VolumeBoundary.lstatEntry,
        children: (String) -> [String]? = VolumeBoundary.directoryNames
    ) -> Finding {
        guard let rootEntry = lstat(root), rootEntry.isDirectory else { return .sameVolume }
        var pending = [root]
        var visited = 0
        while let directory = pending.popLast() {
            for name in children(directory) ?? [] {
                visited += 1
                if visited > maxEntries { return .tooLarge }
                let path = directory + "/" + name
                guard let entry = lstat(path) else { continue }
                if entry.device != rootEntry.device { return .otherVolume(path) }
                if entry.isDirectory { pending.append(path) }
            }
        }
        return .sameVolume
    }

    public static func lstatEntry(_ path: String) -> Entry? {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return Entry(device: UInt64(bitPattern: Int64(info.st_dev)), isDirectory: (info.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Names in a directory, without `.` and `..`; nil when it cannot be read.
    public static func directoryNames(_ path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
