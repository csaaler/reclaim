import Foundation

/// A path normalized for comparison on a case-insensitive, normalization-insensitive file system.
///
/// The path is standardized lexically (no symlink resolution): empty and `.` segments are dropped,
/// `..` removes the preceding segment, and a trailing `/` is removed. Equality and hashing use the
/// case-folded, NFC-normalized form, so `/Users/A` and `/users/a` are the same key.
public struct PathKey: Hashable, Sendable {
    /// The standardized path, original case preserved.
    public let raw: String
    /// Case-folded and NFC-normalized form of `raw`; used for comparison.
    let folded: String

    public init(_ path: String) {
        let isAbsolute = path.hasPrefix("/")
        var segments: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".": continue
            case "..": if !segments.isEmpty { segments.removeLast() }
            default: segments.append(segment)
            }
        }
        let joined = segments.joined(separator: "/")
        raw = isAbsolute ? "/" + joined : joined
        folded = PathKey.fold(raw)
    }

    static func fold(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    var foldedSegments: [Substring] {
        folded.split(separator: "/", omittingEmptySubsequences: true)
    }

    public func isSame(as other: PathKey) -> Bool {
        folded == other.folded
    }

    /// True when `self` is a strict descendant of `ancestor`.
    public func isInside(_ ancestor: PathKey) -> Bool {
        if ancestor.folded == "/" { return folded.count > 1 && folded.hasPrefix("/") }
        return folded.hasPrefix(ancestor.folded + "/")
    }

    public static func == (lhs: PathKey, rhs: PathKey) -> Bool {
        lhs.folded == rhs.folded
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(folded)
    }
}
