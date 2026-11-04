import Foundation

/// Who a location belongs to in By App: definitions, inspectors, installed apps and orphans.
extension BuildRun {
    /// The owner of an app folder (or of a rule match, which is its own app folder), memoized.
    mutating func attribution(appFolder path: String, states: [TrieNode]) -> Owner? {
        if let cached = attributionCache[path] { return cached }
        // Definitions are matched by the trie (paths) and by `resolve` (bundle IDs), so the
        // attributor runs without them; its per-definition pattern loop dominated build time.
        var owner = attributor.attribute(path).map(resolve)
        if owner == nil || owner?.priority != .definition {
            let below = states.reduce(into: Set<Int>()) { $0.formUnion($1.definitionsBelow) }
            if below.count == 1, let d = below.first { owner = definitionOwner(builder.definitions[d]) }
        }
        attributionCache[path] = owner
        return owner
    }

    private func resolve(_ attribution: Attribution) -> Owner {
        if let definition = builder.definitions.first(where: { $0.id == attribution.appKey })
            ?? definition(forBundleID: attribution.appKey) {
            return definitionOwner(definition)
        }
        if attribution.isOrphan {
            // `group.com.apple.x`, `group.net.whatsapp.WhatsApp.shared`: look past the group prefix.
            // Team prefixes are recognised on the original case, then the token is folded.
            let bare = PathKey.fold(OwnerToken.bare(attribution.appKey))
            // A helper or extension of a known app (`net.whatsapp.WhatsApp.ServiceExtension`) belongs to it.
            if let parent = knownBundleIDs.filter({ bare == $0 || bare.hasPrefix($0 + ".") }).max(by: { $0.count < $1.count }) {
                if let definition = definition(forBundleID: parent) { return definitionOwner(definition) }
                if let app = builder.index.app(bundleID: parent) { return indexOwner(app) }
            }
            // Another app from the same vendor is known (`com.microsoft.oneauth` next to Word): the
            // folder may well be shared with it, so never offer it as an orphan.
            if let vendor = OwnerToken.vendor(of: bare), let sibling = vendors[vendor] {
                return Owner(key: attribution.appKey, displayName: attribution.displayName, isInstalled: false,
                             isOrphan: false, priority: .attribution, quitRequirement: nil,
                             viewOnlyReason: "May belong to \(sibling)")
            }
            let strict = !OwnerToken.appleOwnerPrefixes.contains { bare.hasPrefix($0) } && OwnerToken.looksLikeBundleID(bare)
            return Owner(key: attribution.appKey, displayName: attribution.displayName, isInstalled: false,
                         isOrphan: strict, priority: .attribution,
                         quitRequirement: strict ? .mustBeQuit(bundleIDs: [attribution.appKey], processNames: []) : nil)
        }
        if let app = builder.index.app(bundleID: attribution.appKey) { return indexOwner(app) }
        return Owner(key: attribution.appKey, displayName: attribution.displayName, isInstalled: attribution.isInstalled,
                     isOrphan: false, priority: .attribution,
                     quitRequirement: .mustBeQuit(bundleIDs: [attribution.appKey], processNames: []))
    }

    func definition(forBundleID id: String) -> AppDefinition? {
        let folded = PathKey.fold(id)
        return builder.definitions.first { $0.bundleIDs.contains { PathKey.fold($0) == folded } }
    }

    func definitionRequirement(_ definition: AppDefinition) -> AppStateRequirement {
        definition.mustQuitBeforeCleaning
            ? .mustBeQuit(bundleIDs: definition.bundleIDs, processNames: definition.processNames)
            : .none
    }

    func definitionOwner(_ definition: AppDefinition) -> Owner {
        Owner(key: definition.id, displayName: definition.displayName,
              isInstalled: definition.bundleIDs.contains { builder.index.app(bundleID: $0) != nil },
              isOrphan: false, priority: .definition,
              quitRequirement: .mustBeQuit(bundleIDs: definition.bundleIDs, processNames: definition.processNames))
    }

    func indexOwner(_ app: InstalledApp) -> Owner {
        if let definition = definition(forBundleID: app.bundleID) { return definitionOwner(definition) }
        return Owner(key: app.bundleID, displayName: app.name, isInstalled: true, isOrphan: false,
                     priority: .attribution, quitRequirement: .mustBeQuit(bundleIDs: [app.bundleID], processNames: []))
    }

    func inspectorOwner(_ id: String) -> Owner {
        let sectionName = sections.first { $0.inspectorID == id }?.displayName ?? id
        let bundles = inspectorBundleIDs[id] ?? []
        guard let first = bundles.first else {
            return Owner(key: id, displayName: sectionName, isInstalled: true, isOrphan: false,
                         priority: .inspector, quitRequirement: nil)
        }
        if let definition = bundles.lazy.compactMap({ self.definition(forBundleID: $0) }).first {
            return definitionOwner(definition)
        }
        let installed = bundles.lazy.compactMap { self.builder.index.app(bundleID: $0) }.first
        return Owner(key: installed?.bundleID ?? first, displayName: sectionName, isInstalled: installed != nil,
                     isOrphan: false, priority: .inspector,
                     quitRequirement: .mustBeQuit(bundleIDs: bundles, processNames: []))
    }
}
