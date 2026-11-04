import Foundation

/// The last guard before a deletion: standardizes the path, resolves symlinks in the parent
/// (never the final component), and rejects protected, structural, outside-root and replaced paths.
///
/// A relative path is rejected as `.notAbsolute`; a path with a NUL byte or a literal `.` or `..`
/// component as `.notStandardized`. Callers must pass fully standardized absolute paths. An
/// allowed root itself is never deletable.
public struct PathValidator: PathValidating {
    private let protected: ProtectedPaths
    private let structural: [PathKey]
    private let roots: [PathKey]

    /// Folders that are never deletable themselves (their contents may be).
    public static func structuralFolders(home: URL) -> [String] {
        let h = home.path
        return [
            h,
            h + "/Library",
            h + "/Library/Caches",
            h + "/Library/Logs",
            h + "/Library/Application Support",
            h + "/Library/Containers",
            h + "/Library/Group Containers",
            h + "/Library/Developer",
        ]
    }

    public init(home: URL, allowedRoots: [String]? = nil) {
        protected = ProtectedPaths(home: home)
        let resolvedHome = URL(fileURLWithPath: FileSystem.realpath(home.path) ?? home.path)
        var structuralPaths = PathValidator.structuralFolders(home: home)
        if resolvedHome.path != home.path { structuralPaths += PathValidator.structuralFolders(home: resolvedHome) }
        structural = structuralPaths.map { PathKey($0) }
        var rootPaths = allowedRoots ?? [home.path]
        for root in rootPaths { if let r = FileSystem.realpath(root) { rootPaths.append(r) } }
        roots = rootPaths.map { PathKey($0) }
    }

    public func validate(_ path: String, expectedFileID: FileID?) throws(SafetyViolation) -> String {
        guard path.hasPrefix("/") else { throw .notAbsolute(path) }
        guard !path.contains("\0"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw .notStandardized(path)
        }
        let standardized = ProtectedPaths.displayPath(path)
        if standardized == "/" { throw .protected(path) }
        // Cheap lexical check first; the on-disk Photos scan runs once, on the resolved path.
        if protected.isProtected(standardized) { throw .protected(path) }

        guard FileID.of(path: standardized) != nil else { throw .notFound(path) }

        // Resolve the parent only; the final component stays as named, so a symlink is
        // validated as the link itself.
        let url = URL(fileURLWithPath: standardized)
        let last = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        guard let realParent = FileSystem.realpath(parent) else { throw .notFound(path) }
        let resolved = ProtectedPaths.displayPath(realParent == "/" ? "/" + last : realParent + "/" + last)

        if protected.isProtected(resolved) || protected.protects(ancestorOf: resolved) { throw .protected(path) }
        let key = PathKey(resolved)
        if structural.contains(key) || roots.contains(key) { throw .protected(path) }
        guard roots.contains(where: { key == $0 || key.isInside($0) }) else { throw .outsideAllowedRoots(path) }

        guard let id = FileID.of(path: resolved) else { throw .notFound(path) }
        if let expectedFileID, expectedFileID != id { throw .identityChanged(path) }
        return resolved
    }
}
