import Foundation

public struct RuleMatch: Sendable, Hashable {
    public let kind: LocationKind
    public let ownerToken: String
    /// The folder that holds the matched `<app>` folder (for example `~/Library/Caches`).
    public let locationRoot: String
    public let isAppleOwned: Bool

    public init(kind: LocationKind, ownerToken: String, locationRoot: String, isAppleOwned: Bool) {
        self.kind = kind
        self.ownerToken = ownerToken
        self.locationRoot = locationRoot
        self.isAppleOwned = isAppleOwned
    }
}

/// The four generic cache/log locations, matched only at the `<app>` folder depth.
public enum LocationRules {
    /// The four rules as `PathPattern`s, one `*` per `<app>` folder. `match` checks the same shapes.
    static let patterns = [
        "~/Library/Caches/*",
        "~/Library/Logs/*",
        "~/Library/Containers/*/Data/Library/Caches/*",
        "~/Library/Group Containers/*/Library/Caches/*",
    ]

    public static func match(_ path: String, home: URL) -> RuleMatch? {
        let homeKey = PathKey(home.path)
        let pathKey = PathKey(path)
        guard pathKey.isInside(homeKey) else { return nil }
        let homeCount = homeKey.foldedSegments.count
        let raw = pathKey.raw.split(separator: "/").map(String.init)
        let folded = pathKey.foldedSegments.map(String.init)
        guard raw.count > homeCount else { return nil }
        let rel = Array(raw[homeCount...])
        let rf = Array(folded[homeCount...])
        guard rf.first == "library", rf.count >= 3 else { return nil }

        func root(_ count: Int) -> String {
            "/" + raw[0..<(homeCount + count)].joined(separator: "/")
        }
        // `rel[2]` is the `<app>` folder in every rule. Apple ownership is judged on it with its
        // team-ID and group prefixes removed (`group.com.apple.x`, `<TEAM>.groups.com.apple.x`),
        // the same way SnapshotBuilder resolves owners (see `OwnerToken.bare`).
        func result(_ kind: LocationKind, token: String, rootCount: Int) -> RuleMatch {
            RuleMatch(kind: kind, ownerToken: token, locationRoot: root(rootCount),
                      isAppleOwned: OwnerToken.isApple(rel[2]))
        }

        switch rf[1] {
        case "caches" where rf.count == 3:
            return result(.cache, token: rel[2], rootCount: 2)
        case "logs" where rf.count == 3:
            return result(.logs, token: rel[2], rootCount: 2)
        case "containers" where rf.count == 7 && rf[3] == "data" && rf[4] == "library" && rf[5] == "caches":
            return result(.cache, token: rel[2], rootCount: 6)
        case "group containers" where rf.count == 6 && rf[3] == "library" && rf[4] == "caches":
            return result(.cache, token: OwnerToken.stripTeamPrefix(rel[2]), rootCount: 5)
        default:
            return nil
        }
    }
}
