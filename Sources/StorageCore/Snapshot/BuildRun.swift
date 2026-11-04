import Foundation

/// One `SnapshotBuilder.build` call: the trie and lookups set up for it, the walk over the scan tree,
/// and the locations it emits. Emitting is in `BuildRun+Emit.swift`, owner resolution in
/// `BuildRun+Owners.swift`.
struct BuildRun {
    /// Who a location belongs to in By App.
    struct Owner {
        enum Priority: Int { case attribution = 0, inspector = 1, definition = 2 }

        let key: String
        let displayName: String
        let isInstalled: Bool
        let isOrphan: Bool
        let priority: Priority
        /// For location-rule matches: what must be quit, or nil when the owner is unknown.
        let quitRequirement: AppStateRequirement?
        /// Why the owner's generic folders are view-only, when it is not the default reason.
        var viewOnlyReason: String? = nil

        static let noDefinition = "No definition for this app yet"
    }

    struct FootprintAccumulator {
        var owner: Owner
        var locations: [AttributedLocation] = []
        var inspectorIDs: Set<String> = []

        /// Adds a location; the owner with the highest priority names the footprint.
        mutating func add(_ location: AttributedLocation, owner: Owner, inspectorID: String?) {
            locations.append(location)
            if owner.priority.rawValue > self.owner.priority.rawValue { self.owner = owner }
            if let inspectorID { inspectorIDs.insert(inspectorID) }
        }
    }

    let builder: SnapshotBuilder
    let sections: [InspectorSection]
    let inspectorBundleIDs: [String: [String]]
    let trie: TrieNode
    let homeKey: PathKey
    let userRootKeys: [PathKey]
    let appRootKeys: [PathKey]
    let systemRootKeys: [PathKey]
    let trashKey: PathKey
    /// Large files directly inside a user or code root, by that root. The scan tree holds
    /// directories only, so these are the only top-level files that can be listed on their own.
    let looseFiles: [PathKey: [LargeFile]]
    /// Inspectors whose claims count as "Developer tools" in By Category.
    let developerInspectorIDs: Set<String>
    /// Per inspector: items with paths, for the kind and requirement of claimed locations.
    let itemsByInspector: [String: [(keys: [PathKey], item: InspectorItem)]]

    let attributor: Attributor
    /// Installed, defined and inspected bundle IDs (folded), for attaching helper folders to their app.
    let knownBundleIDs: [String]
    /// Reverse-DNS vendor prefix (`com.microsoft`) → display name of a known app from that vendor.
    let vendors: [String: String]
    var attributionCache: [String: Owner?] = [:]
    var footprints: [String: FootprintAccumulator] = [:]
    var categories: [StorageCategory: [AttributedLocation]] = [:]

    static let unknownOwnerNote = "owner unknown — make sure no related app is running"

    init(
        builder: SnapshotBuilder, sections: [InspectorSection], claims: [String: [String]],
        inspectorBundleIDs: [String: [String]], largeFiles: [LargeFile] = [],
        unreadablePaths: [String] = []
    ) {
        self.builder = builder
        self.sections = sections
        self.inspectorBundleIDs = inspectorBundleIDs
        let h = builder.home.path
        homeKey = PathKey(h)

        let userRoots = SnapshotBuilder.userFolders.map { h + "/" + $0 }
            + builder.codeRoots.compactMap { PathPattern.absolutePattern($0, home: builder.home) }
        let appRoots = ["/Applications", h + "/Applications"]
        trie = Self.makeTrie(builder: builder, claims: claims, descendInto: userRoots + appRoots)
        userRootKeys = userRoots.map { PathKey($0) }
        looseFiles = Self.makeLooseFiles(largeFiles, userRootKeys: userRootKeys)
        appRootKeys = appRoots.map { PathKey($0) }
        systemRootKeys = ["/Library", "/private", "/System"].map { PathKey($0) }
        trashKey = PathKey(h + "/.Trash")

        var items: [String: [(keys: [PathKey], item: InspectorItem)]] = [:]
        for section in sections {
            items[section.inspectorID] = section.items.filter { !$0.paths.isEmpty }.map { ($0.paths.map { PathKey($0) }, $0) }
        }
        itemsByInspector = items
        developerInspectorIDs = Set(sections.filter { $0.category == .developerTools }.map(\.inspectorID))
        attributor = Attributor(index: builder.index, definitions: [], home: builder.home,
                                unreadablePaths: Set(unreadablePaths))
        let named = Self.namedBundleIDs(builder: builder, sections: sections, inspectorBundleIDs: inspectorBundleIDs)
        knownBundleIDs = named.map { PathKey.fold($0.id) }
        vendors = Self.makeVendors(named)
    }

    /// The trie of every path the walk stops at or passes through: inspector claims, definition
    /// locations, location rules, app folders, and the children of `descendInto` roots.
    private static func makeTrie(builder: SnapshotBuilder, claims: [String: [String]], descendInto roots: [String]) -> TrieNode {
        let trie = TrieNode()
        func absolute(_ pattern: String) -> String? { PathPattern.absolutePattern(pattern, home: builder.home) }
        // Claims first so that ties resolve to the lowest inspector ID.
        for id in claims.keys.sorted() {
            for path in claims[id] ?? [] where path.hasPrefix("/") {
                trie.insert(TrieNode.segments(path), target: .claim(id))
            }
        }
        for (d, definition) in builder.definitions.enumerated() {
            for (l, location) in definition.locations.enumerated() {
                guard let path = absolute(location.pattern) else { continue }
                trie.insert(TrieNode.segments(path), target: .definition(d, l))
            }
        }
        for rule in LocationRules.patterns {
            trie.insert(TrieNode.segments(absolute(rule)!), target: .rule)
        }
        for folder in ["~/Library/Application Support/*", "~/Library/Containers/*", "~/Library/Group Containers/*"] {
            trie.insert(TrieNode.segments(absolute(folder)!), target: .appFolder)
        }
        for root in roots {
            trie.insert(TrieNode.segments(root) + ["*"], target: .descend)
        }
        return trie
    }

    private static func makeLooseFiles(_ largeFiles: [LargeFile], userRootKeys: [PathKey]) -> [PathKey: [LargeFile]] {
        var loose: [PathKey: [LargeFile]] = [:]
        for file in largeFiles {
            let parent = PathKey((file.path as NSString).deletingLastPathComponent)
            if userRootKeys.contains(parent) { loose[parent, default: []].append(file) }
        }
        return loose
    }

    /// Bundle IDs with the name of their app: installed apps, then definitions, then inspectors.
    private static func namedBundleIDs(
        builder: SnapshotBuilder, sections: [InspectorSection], inspectorBundleIDs: [String: [String]]
    ) -> [(id: String, name: String)] {
        var named: [(id: String, name: String)] = builder.index.apps.sorted { $0.name < $1.name }.map { ($0.bundleID, $0.name) }
        named += builder.definitions.flatMap { d in d.bundleIDs.map { ($0, d.displayName) } }
        for id in inspectorBundleIDs.keys.sorted() {
            let name = sections.first { $0.inspectorID == id }?.displayName ?? id
            named += (inspectorBundleIDs[id] ?? []).map { ($0, name) }
        }
        return named
    }

    /// Vendor prefix → the first named app from that vendor.
    private static func makeVendors(_ named: [(id: String, name: String)]) -> [String: String] {
        var vendors: [String: String] = [:]
        for entry in named {
            guard let vendor = OwnerToken.vendor(of: PathKey.fold(entry.id)) else { continue }
            if vendors[vendor] == nil { vendors[vendor] = entry.name }
        }
        return vendors
    }

    // MARK: Walk

    mutating func walk(_ root: DirectorySummary) {
        var states = [trie]
        for segment in TrieNode.segments(root.path) {
            states = states.flatMap { $0.next(segment) }
        }
        _ = visit(root, states: states, owner: nil)
    }

    /// Returns the bytes of `node` covered by emitted locations. In app-folder mode (`owner` set),
    /// bytes not covered are left for the app folder's remainder; otherwise every byte is emitted.
    private mutating func visit(_ node: DirectorySummary, states: [TrieNode], owner: (path: String, owner: Owner?)?) -> Int64 {
        var claimID: String?
        var definition: (Int, Int)?
        var isRule = false, isAppFolder = false
        for state in states {
            for target in state.targets {
                switch target {
                case .claim(let id): if claimID == nil || id < claimID! { claimID = id }
                case .definition(let d, let l): if definition == nil || (d, l) < definition! { definition = (d, l) }
                case .rule: isRule = true
                case .appFolder: isAppFolder = true
                case .descend: break
                }
            }
        }
        let isPrefix = states.contains { $0.hasChildren }
        let strongBelow = states.contains { $0.strongBelow }

        if let claimID {
            emitClaim(node, inspectorID: claimID)
            return node.allocatedBytes
        }
        if case let (d, l)? = definition {
            if !strongBelow {
                emitDefinition(node, definition: d, location: l)
                return node.allocatedBytes
            }
            // A claim lies inside this definition location: list the claim, keep the rest as the app's.
            let definitionOwner = definitionOwner(builder.definitions[d])
            let covered = visitChildren(node, states: states, owner: (node.path, definitionOwner))
            emitRemainder(node, bytes: node.allocatedBytes - covered, owner: definitionOwner, isAppFolder: true)
            return node.allocatedBytes
        }
        if !isPrefix && builder.protected.isProtected(node.path) {
            emit(node, kind: .userData, note: PathKey(node.path) == trashKey ? "Trash" : nil, cleanability: .protected,
                 source: owner?.owner == nil ? .unattributed : .generic, requirement: .none, owner: owner?.owner)
            return node.allocatedBytes
        }
        if isRule && !strongBelow, let rule = LocationRules.match(node.path, home: builder.home) {
            emitRule(node, rule: rule, owner: owner?.owner ?? attribution(appFolder: node.path, states: states))
            return node.allocatedBytes
        }
        if isAppFolder && owner == nil {
            let folderOwner = attribution(appFolder: node.path, states: states)
            if !strongBelow && (folderOwner?.isOrphan == true || !isPrefix) {
                emitAppFolder(node, owner: folderOwner)
                return node.allocatedBytes
            }
            let covered = visitChildren(node, states: states, owner: (node.path, folderOwner))
            emitRemainder(node, bytes: node.allocatedBytes - covered, owner: folderOwner, isAppFolder: true)
            return node.allocatedBytes
        }
        if isPrefix {
            var covered = visitChildren(node, states: states, owner: owner)
            if owner != nil { return covered }
            covered += emitLooseFiles(in: node, available: node.allocatedBytes - covered)
            emitRemainder(node, bytes: node.allocatedBytes - covered, owner: nil, isAppFolder: false)
            return node.allocatedBytes
        }
        if owner != nil { return 0 }
        emitLeaf(node)
        return node.allocatedBytes
    }

    private mutating func visitChildren(_ node: DirectorySummary, states: [TrieNode], owner: (path: String, owner: Owner?)?) -> Int64 {
        var covered: Int64 = 0
        for child in node.children {
            let name = PathKey.fold(String(child.path.split(separator: "/").last ?? ""))
            let next = states.flatMap { $0.next(name) }
            if next.isEmpty && owner != nil { continue }
            covered += visit(child, states: next, owner: owner)
        }
        return covered
    }

    // MARK: Assembly

    func assemble() -> ([AppFootprint], [CategoryTotal]) {
        var accumulators = footprints
        // Inspectors join the footprint of the app they inspect, even without claimed locations.
        for (id, bundles) in inspectorBundleIDs {
            for bundle in bundles {
                let key = definition(forBundleID: bundle)?.id ?? builder.index.app(bundleID: bundle)?.bundleID ?? bundle
                accumulators[key]?.inspectorIDs.insert(id)
            }
        }
        let apps = accumulators.values.map { acc in
            AppFootprint(
                id: acc.owner.key,
                displayName: acc.owner.displayName,
                isInstalled: acc.owner.isInstalled,
                isOrphan: acc.owner.isOrphan,
                locations: acc.locations.sorted(by: Self.largestFirst),
                inspectorIDs: acc.inspectorIDs.sorted())
        }
        .sorted { $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.id < $1.id }

        let totals = StorageCategory.allCases.map { category in
            let locations = (categories[category] ?? []).sorted(by: Self.largestFirst)
            return CategoryTotal(category: category, bytes: locations.reduce(0) { $0 + $1.allocatedBytes }, locations: locations)
        }
        .sorted { $0.bytes > $1.bytes }
        return (apps, totals)
    }

    private static func largestFirst(_ a: AttributedLocation, _ b: AttributedLocation) -> Bool {
        a.allocatedBytes != b.allocatedBytes ? a.allocatedBytes > b.allocatedBytes : a.path < b.path
    }
}
