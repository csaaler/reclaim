import Foundation

/// Path patterns used by definitions, inspectors and the protected list.
///
/// - A leading `~/` (or a bare `~`) expands to the home directory.
/// - A leading `/` makes the pattern absolute; it is used as-is.
/// - `*` matches any run of characters within one path segment (including none). There is no `**`.
/// - A pattern without a leading `/` or `~` is relative: `matches` compares it against the trailing
///   segments of a path (`*.photoslibrary` matches `/a/X.photoslibrary`). `expand` returns nothing for it.
///
/// Matching is case-insensitive and normalization-insensitive (see `PathKey`).
public enum PathPattern {
    /// Paths that currently exist and match `pattern`, sorted. Directory entries matched by `*` are
    /// only descended into when they are real directories (symlinks are not followed).
    public static func expand(_ pattern: String, home: URL) -> [String] {
        guard let absolute = absolutePattern(pattern, home: home) else { return [] }
        let segments = PathKey(absolute).raw.split(separator: "/").map(String.init)
        var results = ["/"]
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            var next: [String] = []
            for base in results {
                if segment.contains("*") {
                    guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
                    let foldedSegment = PathKey.fold(segment)
                    for name in names where globMatches(foldedSegment, PathKey.fold(name)) {
                        let candidate = join(base, name)
                        if isLast || isRealDirectory(candidate) { next.append(candidate) }
                    }
                } else {
                    let candidate = join(base, segment)
                    if exists(candidate) { next.append(candidate) }
                }
            }
            results = next
            if results.isEmpty { return [] }
        }
        return Array(Set(results)).sorted()
    }

    /// Whether `path` matches `pattern` exactly (same number of segments, each segment matching).
    /// Relative patterns match the trailing segments of `path`.
    public static func matches(_ pattern: String, path: String, home: URL) -> Bool {
        let pathSegments = PathKey(path).foldedSegments
        if let absolute = absolutePattern(pattern, home: home) {
            let patternSegments = PathKey(absolute).foldedSegments
            return patternSegments.count == pathSegments.count
                && zip(patternSegments, pathSegments).allSatisfy { globMatches($0, $1) }
        }
        let patternSegments = PathKey(pattern).foldedSegments
        guard !patternSegments.isEmpty, patternSegments.count <= pathSegments.count else { return false }
        return zip(patternSegments, pathSegments.suffix(patternSegments.count)).allSatisfy { globMatches($0, $1) }
    }

    /// Whether some path matching `a` equals, contains or lies inside some path matching `b`: the
    /// shared leading segments can all match one common name. Relative patterns never overlap.
    public static func overlaps(_ a: String, _ b: String, home: URL) -> Bool {
        guard let absoluteA = absolutePattern(a, home: home), let absoluteB = absolutePattern(b, home: home) else {
            return false
        }
        let segmentsA = PathKey(absoluteA).foldedSegments, segmentsB = PathKey(absoluteB).foldedSegments
        return zip(segmentsA, segmentsB).allSatisfy { globsIntersect($0, $1) }
    }

    /// Whether two `*`-only globs over one segment match at least one common name. Walks both
    /// globs side by side over a shared name; a state is a position in each glob.
    static func globsIntersect<A: StringProtocol, B: StringProtocol>(_ a: A, _ b: B) -> Bool {
        let p = Array(a), q = Array(b)
        var seen = Set<[Int]>(), pending = [[0, 0]]
        while let state = pending.popLast() {
            guard seen.insert(state).inserted else { continue }
            let i = state[0], j = state[1]
            if i == p.count && j == q.count { return true }
            // A `*` may match nothing.
            if i < p.count, p[i] == "*" { pending.append([i + 1, j]) }
            if j < q.count, q[j] == "*" { pending.append([i, j + 1]) }
            // Both consume one character of the shared name.
            guard i < p.count, j < q.count else { continue }
            switch (p[i] == "*", q[j] == "*") {
            case (false, false): if p[i] == q[j] { pending.append([i + 1, j + 1]) }
            case (true, false): pending.append([i, j + 1])
            case (false, true): pending.append([i + 1, j])
            case (true, true): break
            }
        }
        return false
    }

    /// The pattern with `~` expanded, or nil for a relative pattern.
    static func absolutePattern(_ pattern: String, home: URL) -> String? {
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") { return home.path + "/" + pattern.dropFirst(2) }
        if pattern.hasPrefix("/") { return pattern }
        return nil
    }

    private static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// `*`-only glob over one segment.
    static func globMatches<P: StringProtocol, S: StringProtocol>(_ pattern: P, _ text: S) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] != "*", p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
