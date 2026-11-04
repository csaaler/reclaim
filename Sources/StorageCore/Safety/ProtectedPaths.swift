import Foundation

/// Matches paths against `ProtectedPathList`. Paths are display paths (`/Users/...`); a
/// `/System/Volumes/Data` prefix is stripped before matching.
public struct ProtectedPaths: Sendable {
    private let entries: [String]
    private let home: URL

    public init(home: URL) {
        self.home = home
        var all = ProtectedPathList.entries(home: home)
        let resolved = URL(fileURLWithPath: FileSystem.realpath(home.path) ?? home.path)
        if resolved.path != home.path {
            all += ProtectedPathList.entries(home: resolved).filter { $0.hasPrefix(resolved.path + "/") }
        }
        entries = all
    }

    /// True when the path is equal to or inside a protected entry, or is a lexical ancestor of
    /// one (e.g. `~/Library`, which contains `~/Library/Keychains`).
    public func isProtected(_ path: String) -> Bool {
        let display = ProtectedPaths.displayPath(path)
        return matchesAsSameOrInside(display) || matchesAsLexicalAncestor(display)
    }

    /// True when deleting the path would delete a protected entry: a lexical ancestor of a
    /// protected entry, or (for a directory) a path that contains a `*.photoslibrary` within
    /// three levels, found on disk without following symlinks. A directory in that range that
    /// cannot be listed counts as containing one (fail closed).
    public func protects(ancestorOf path: String) -> Bool {
        let display = ProtectedPaths.displayPath(path)
        if matchesAsLexicalAncestor(display) { return true }
        return ProtectedPaths.containsPhotosLibrary(display, depth: 3)
    }

    /// The first protected entry that `pattern` (a `~/` or absolute `PathPattern`) could touch:
    /// some path it matches equals, lies inside, or is an ancestor of the entry. Nil when it
    /// touches none, and for relative patterns, which never expand to a path.
    ///
    /// This is a check on the pattern's text. Whether a matched folder *contains* a
    /// `*.photoslibrary` further down can only be decided on disk, by `protects(ancestorOf:)`.
    public func overlaps(pattern: String) -> String? {
        let absolute: String
        if pattern.hasPrefix("~/") {
            absolute = home.path + "/" + pattern.dropFirst(2)
        } else if pattern.hasPrefix("/") {
            absolute = pattern
        } else {
            return nil
        }
        let patternSegments = PathKey(absolute).foldedSegments
        guard !isInsideException(segments: patternSegments) else { return nil }
        for entry in entries {
            if !entry.hasPrefix("/") {
                // Anywhere pattern (`*.photoslibrary`): some leading part of the pattern is a match.
                let hit = patternSegments.indices.contains { index in
                    PathPattern.matches(entry, path: "/" + patternSegments.prefix(index + 1).joined(separator: "/"), home: home)
                }
                if hit { return entry }
                continue
            }
            // Literal or absolute glob entry: equal, inside or ancestor means the shared leading
            // segments agree, with a `*` on either side matching the other side's segment.
            let entrySegments = PathKey(entry).foldedSegments
            let shared = min(patternSegments.count, entrySegments.count)
            let agree = zip(patternSegments.prefix(shared), entrySegments.prefix(shared)).allSatisfy { p, e in
                PathPattern.globMatches(p, e) || PathPattern.globMatches(e, p)
            }
            if shared > 0 && agree { return entry }
        }
        return nil
    }

    /// Whether every path the pattern can match lies in an exception (`/usr/local`).
    private func isInsideException(segments: [Substring]) -> Bool {
        ProtectedPathList.exceptions.contains { exception in
            let exceptionSegments = PathKey(exception).foldedSegments
            return segments.count >= exceptionSegments.count
                && zip(segments, exceptionSegments).allSatisfy { $0 == $1 }
        }
    }

    // MARK: - Matching

    static func displayPath(_ path: String) -> String {
        let raw = PathKey(path).raw
        let prefix = "/System/Volumes/Data"
        let options: String.CompareOptions = [.caseInsensitive, .anchored]
        if raw.compare(prefix, options: options) == .orderedSame { return "/" }
        if let range = raw.range(of: prefix + "/", options: options) {
            return "/" + raw[range.upperBound...]
        }
        return raw
    }

    private func prefixes(of path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for segment in PathKey(path).raw.split(separator: "/") {
            current += "/" + segment
            result.append(current)
        }
        return result
    }

    private func isInsideException(_ path: String, entry: String) -> Bool {
        let key = PathKey(path)
        let entryKey = PathKey(entry)
        return ProtectedPathList.exceptions.contains { exception in
            let ex = PathKey(exception)
            return ex.isInside(entryKey) && (key == ex || key.isInside(ex))
        }
    }

    private func matchesAsSameOrInside(_ path: String) -> Bool {
        let key = PathKey(path)
        let candidates = prefixes(of: path)
        for entry in entries {
            if entry.hasPrefix("/") && !entry.contains("*") {
                let entryKey = PathKey(entry)
                if (key == entryKey || key.isInside(entryKey)) && !isInsideException(path, entry: entry) {
                    return true
                }
            } else if candidates.contains(where: { PathPattern.matches(entry, path: $0, home: home) }) {
                return true
            }
        }
        return false
    }

    private func matchesAsLexicalAncestor(_ path: String) -> Bool {
        let key = PathKey(path)
        let pathSegments = key.foldedSegments
        for entry in entries {
            if entry.hasPrefix("/") && !entry.contains("*") {
                if PathKey(entry).isInside(key) { return true }
            } else if entry.hasPrefix("/") {
                let entrySegments = PathKey(entry).foldedSegments
                guard pathSegments.count < entrySegments.count else { continue }
                if zip(entrySegments, pathSegments).allSatisfy({ PathPattern.globMatches($0, $1) }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Disk checks

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func containsPhotosLibrary(_ path: String, depth: Int) -> Bool {
        guard depth > 0, isRealDirectory(path) else { return false }
        // Fail closed: a directory we cannot list might hold a photos library.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
        for name in names {
            let child = path == "/" ? "/" + name : path + "/" + name
            if PathPattern.matches("*.photoslibrary", path: child, home: URL(fileURLWithPath: "/")) {
                return true
            }
            if containsPhotosLibrary(child, depth: depth - 1) { return true }
        }
        return false
    }
}
