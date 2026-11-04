import Foundation

/// Small file system helpers shared by the safety checks.
enum FileSystem {
    /// The path with every symlink resolved (`realpath(3)`), or nil when it does not exist.
    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
