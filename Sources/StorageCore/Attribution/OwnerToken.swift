import Foundation

/// Helpers for owner tokens: the bundle-ID-like folder names under `~/Library/Application Support`,
/// `Caches`, `Logs`, `Containers` and `Group Containers` that say which app a folder belongs to.
public enum OwnerToken {
    /// Whether an owner token looks like a reverse-DNS bundle ID: ASCII letters, digits and hyphens,
    /// at least three non-empty dot-separated segments, no spaces, and no all-digit segment (so
    /// versioned names such as `node-v18.0.1` are not taken for apps). Letters are matched without
    /// regard to case, since real bundle IDs (`com.hnc.Discord`) use capitals.
    public static func looksLikeBundleID(_ token: String) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                && !segment.allSatisfy(\.isNumber)
        }
    }

    /// Removes an Apple team-ID prefix (`UBF8T346G9.`): exactly 10 uppercase ASCII letters or digits,
    /// matched on the original (unfolded) text so a real segment such as `consulting.` is kept.
    public static func stripTeamPrefix(_ id: String) -> String {
        let chars = Array(id)
        guard chars.count > 11, chars[10] == ".",
              chars[0..<10].allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) else { return id }
        return String(chars[11...])
    }

    /// The first two reverse-DNS segments of a folded bundle ID (`com.microsoft`), or nil.
    static func vendor(of id: String) -> String? {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, !segments[0].isEmpty, !segments[1].isEmpty else { return nil }
        return segments[0] + "." + segments[1]
    }

    /// Owner tokens that belong to Apple (Shortcuts keeps its data under its old `is.workflow` ID).
    static let appleOwnerPrefixes = ["com.apple.", "is.workflow."]

    /// An owner token without its team-ID and `group.`/`groups.` prefixes (`ABCDE12345.group.com.x`
    /// becomes `com.x`). Team prefixes are recognised on the original case.
    static func bare(_ id: String) -> String {
        var token = stripTeamPrefix(id)
        for prefix in ["group.", "groups."] where token.lowercased().hasPrefix(prefix) { token.removeFirst(prefix.count) }
        return stripTeamPrefix(token)
    }

    /// True when the token, once bare, starts with one of `appleOwnerPrefixes` (case-insensitive).
    static func isApple(_ id: String) -> Bool {
        let bare = bare(id).lowercased()
        return appleOwnerPrefixes.contains { bare.hasPrefix($0) }
    }
}
