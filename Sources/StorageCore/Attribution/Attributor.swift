import Foundation

public struct Attribution: Sendable, Hashable {
    public let appKey: String
    public let displayName: String
    public let isInstalled: Bool
    public let isOrphan: Bool

    public init(appKey: String, displayName: String, isInstalled: Bool, isOrphan: Bool) {
        self.appKey = appKey
        self.displayName = displayName
        self.isInstalled = isInstalled
        self.isOrphan = isOrphan
    }
}

/// Maps a path to the app that owns it. Order: definition, container metadata, owner token = bundle ID,
/// folder name = installed app name. Returns nil when nothing matches.
public struct Attributor: Sendable {
    public let index: AppIndex
    public let definitions: [AppDefinition]
    public let home: URL
    /// Folders the scan could not open. Their container metadata is not read: without Full Disk
    /// Access the read would wait on a "data from other apps" privacy prompt.
    public let unreadablePaths: Set<String>

    public init(index: AppIndex, definitions: [AppDefinition], home: URL, unreadablePaths: Set<String> = []) {
        self.index = index
        self.definitions = definitions
        self.home = home
        self.unreadablePaths = unreadablePaths
    }

    public func attribute(_ path: String) -> Attribution? {
        let homeKey = PathKey(home.path)
        let pathKey = PathKey(path)
        let homeCount = homeKey.foldedSegments.count
        let raw = pathKey.raw.split(separator: "/").map(String.init)
        let folded = pathKey.foldedSegments.map(String.init)
        let inHome = pathKey.isInside(homeKey)
        let rel = inHome ? Array(raw[homeCount...]) : []
        let rf = inHome ? Array(folded[homeCount...]) : []

        // Owner tokens: first folder below a known Library root.
        var token: String?
        var metadataID: String?
        if rf.count >= 3, rf[0] == "library" {
            switch rf[1] {
            case "containers":
                token = rel[2]
                metadataID = containerIdentifier(rel[2])
            case "group containers":
                token = OwnerToken.stripTeamPrefix(rel[2])
            case "application support", "caches", "logs":
                token = rel[2]
            default: break
            }
        }
        if let rule = LocationRules.match(path, home: home) { token = rule.ownerToken }

        // 1. Definition: a location pattern covers the path (or an ancestor), or a bundle ID matches.
        let candidates = [token, metadataID].compactMap { $0 }
        for definition in definitions {
            var claimed = definition.locations.contains { location in
                (0..<max(raw.count, 1)).contains { drop in
                    let ancestor = "/" + raw.dropLast(drop).joined(separator: "/")
                    return !raw.dropLast(drop).isEmpty
                        && PathPattern.matches(location.pattern, path: ancestor, home: home)
                }
            }
            if !claimed {
                claimed = definition.bundleIDs.contains { id in
                    candidates.contains { PathKey.fold($0) == PathKey.fold(id) }
                }
            }
            if claimed {
                let installed = definition.bundleIDs.contains { index.app(bundleID: $0) != nil }
                return Attribution(appKey: definition.id, displayName: definition.displayName,
                                   isInstalled: installed, isOrphan: false)
            }
        }

        // 2. Container metadata identifier, 3. owner token equal to a bundle ID.
        for id in [metadataID, token].compactMap({ $0 }) {
            if let app = index.app(bundleID: id) ?? index.app(teamPrefixedGroup: id) {
                return Attribution(appKey: app.bundleID, displayName: app.name, isInstalled: true, isOrphan: false)
            }
        }

        // 4. Folder name equal to an installed app name.
        if rf.count >= 3, rf[0] == "library", ["application support", "caches", "logs"].contains(rf[1]),
           let app = index.app(named: rel[2]) {
            return Attribution(appKey: app.bundleID, displayName: app.name, isInstalled: true, isOrphan: false)
        }

        // Orphan: reverse-DNS owner with no installed app, not Apple, no definition.
        if let owner = metadataID ?? token, owner.filter({ $0 == "." }).count >= 2,
           !OwnerToken.isApple(owner) {
            return Attribution(appKey: owner, displayName: owner, isInstalled: false, isOrphan: true)
        }
        return nil
    }

    private func containerIdentifier(_ folder: String) -> String? {
        let container = home.appendingPathComponent("Library/Containers/\(folder)")
        guard !unreadablePaths.contains(container.path) else { return nil }
        let url = container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["MCMMetadataIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
