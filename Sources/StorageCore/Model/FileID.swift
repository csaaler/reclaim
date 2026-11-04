import Darwin

/// Identity of a file system object (device + inode). Used to detect that a path
/// was replaced between scan and cleanup, and to count hard links once.
public struct FileID: Hashable, Sendable, Codable {
    public let device: Int32
    public let inode: UInt64

    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// The identity of the object at `path`, via `lstat` (does not follow symlinks).
    /// Returns nil when nothing exists at `path`.
    public static func of(path: String) -> FileID? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }
}
