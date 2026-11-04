import Foundation

/// Turning walked scan nodes into `AttributedLocation`s, filed by category and by app.
extension BuildRun {
    mutating func emitClaim(_ node: DirectorySummary, inspectorID: String) {
        let key = PathKey(node.path)
        // Items whose paths fall inside (or at) the claimed folder.
        let covering = (itemsByInspector[inspectorID] ?? []).filter { entry in
            entry.keys.contains { $0 == key || $0.isInside(key) }
        }.map(\.item)
        let kind = Self.dominantKind(covering)
        let exact = covering.count == 1 && covering[0].paths.contains { PathKey($0) == key } ? covering[0] : nil
        let inspectorName = sections.first { $0.inspectorID == inspectorID }?.displayName ?? inspectorID
        emit(node, kind: kind, note: exact?.title ?? "Managed by \(inspectorName)",
             cleanability: .claimed(inspectorID: inspectorID), source: .inspector(inspectorID),
             requirement: Self.strictestRequirement(covering.map(\.requirement)),
             owner: inspectorOwner(inspectorID), inspectorID: inspectorID)
    }

    /// The risk holding the most bytes among `items` (ties go to the riskier one); `.rebuildable`
    /// when there are none, since an inspector manages the folder.
    static func dominantKind(_ items: [InspectorItem]) -> LocationKind {
        var bytes: [RiskLevel: Int64] = [:]
        for item in items { bytes[item.risk, default: 0] += max(0, item.allocatedBytes) }
        guard let risk = bytes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key })?.key else {
            return .rebuildable
        }
        switch risk {
        case .cache: return .cache
        case .rebuildable: return .rebuildable
        case .userData: return .userData
        }
    }

    /// Must-be-quit beats must-be-running beats none; within a kind, the one naming more apps wins.
    static func strictestRequirement(_ requirements: [AppStateRequirement]) -> AppStateRequirement {
        func rank(_ r: AppStateRequirement) -> (Int, Int) {
            switch r {
            case .mustBeQuit(let ids, let names): (2, ids.count + names.count)
            case .mustBeRunning(let ids, let names, _): (1, ids.count + names.count)
            case .none: (0, 0)
            }
        }
        return requirements.max { rank($0) < rank($1) } ?? .none
    }

    mutating func emitDefinition(_ node: DirectorySummary, definition d: Int, location l: Int) {
        let definition = builder.definitions[d]
        let location = definition.locations[l]
        emit(node, kind: location.kind, note: location.note, cleanability: .cleanable,
             source: .definition(definition.id), requirement: definitionRequirement(definition),
             owner: definitionOwner(definition))
    }

    mutating func emitRule(_ node: DirectorySummary, rule: RuleMatch, owner: Owner?) {
        let requirement = owner?.quitRequirement
        emit(node, kind: rule.kind,
             note: requirement == nil ? Self.unknownOwnerNote : nil,
             cleanability: rule.isAppleOwned ? .viewOnly(reason: "Apple system cache") : .cleanable,
             source: .locationRule, requirement: requirement ?? .none, owner: owner)
    }

    mutating func emitAppFolder(_ node: DirectorySummary, owner: Owner?) {
        if let owner, owner.isOrphan {
            emit(node, kind: .userData, note: "App no longer installed", cleanability: .cleanable,
                 source: .generic, requirement: owner.quitRequirement ?? .none, owner: owner)
        } else if let owner {
            emit(node, kind: .userData, note: nil, cleanability: .viewOnly(reason: owner.viewOnlyReason ?? Owner.noDefinition),
                 source: .generic, requirement: .none, owner: owner)
        } else {
            emit(node, kind: .userData, note: nil, cleanability: .viewOnly(reason: "Not attributed to an app"),
                 source: .unattributed, requirement: .none, owner: nil)
        }
    }

    /// Large files directly in a user or code root become cleanable 🔴 locations; their bytes leave
    /// the folder's remainder. A file that does not fit in the bytes left (a hard link counted
    /// elsewhere) stays in the remainder, so no byte is listed twice. Returns the bytes emitted.
    mutating func emitLooseFiles(in node: DirectorySummary, available: Int64) -> Int64 {
        guard let files = looseFiles[PathKey(node.path)] else { return 0 }
        var emitted: Int64 = 0
        for file in files.sorted(by: { $0.allocatedBytes > $1.allocatedBytes }) {
            guard file.allocatedBytes > 0, emitted + file.allocatedBytes <= available else { continue }
            let leaf = DirectorySummary(path: file.path, allocatedBytes: file.allocatedBytes, fileCount: 1,
                                        newestModification: file.modified, isUnreadable: false, children: [])
            // `emit` still applies the protected-path check.
            emit(leaf, kind: .userData, note: nil, cleanability: .cleanable,
                 source: .unattributed, requirement: .none, owner: nil)
            emitted += file.allocatedBytes
        }
        return emitted
    }

    mutating func emitRemainder(_ node: DirectorySummary, bytes: Int64, owner: Owner?, isAppFolder: Bool) {
        let reason = isAppFolder
            ? (owner.map { $0.viewOnlyReason ?? Owner.noDefinition } ?? "Not attributed to an app")
            : "Files directly in this folder"
        emit(node, bytes: bytes, kind: .userData,
             note: isAppFolder ? "Everything in this folder not listed separately" : "Files directly in this folder; subfolders are listed separately",
             cleanability: .viewOnly(reason: reason),
             source: owner == nil ? .unattributed : .generic, requirement: .none, owner: owner)
    }

    mutating func emitLeaf(_ node: DirectorySummary) {
        let key = PathKey(node.path)
        let parent = PathKey((key.raw as NSString).deletingLastPathComponent)
        if appRootKeys.contains(where: { key.isInside($0) }) {
            if key.raw.lowercased().hasSuffix(".app") {
                let app = builder.index.apps.first { PathKey($0.path) == key }
                emit(node, kind: .rebuildable, note: "App bundle; reinstall to restore",
                     cleanability: .viewOnly(reason: "App bundle; uninstall the app to remove it"),
                     source: app == nil ? .unattributed : .generic, requirement: .none, owner: app.map(indexOwner))
            } else {
                emit(node, kind: .userData, note: "Folder in Applications",
                     cleanability: .viewOnly(reason: "Not an app bundle"),
                     source: .unattributed, requirement: .none, owner: nil)
            }
        } else if userRootKeys.contains(parent) {
            // Only direct children of a user or code root are offered for cleanup.
            emit(node, kind: .userData, note: nil, cleanability: .cleanable,
                 source: .unattributed, requirement: .none, owner: nil)
        } else if userRootKeys.contains(where: { key.isInside($0) }) {
            emit(node, kind: .userData, note: nil,
                 cleanability: .viewOnly(reason: "Inside a folder whose contents are listed separately"),
                 source: .unattributed, requirement: .none, owner: nil)
        } else {
            emit(node, kind: .userData, note: nil, cleanability: .viewOnly(reason: "Not covered by a definition or inspector"),
                 source: .unattributed, requirement: .none, owner: nil)
        }
    }

    mutating func emit(
        _ node: DirectorySummary,
        bytes: Int64? = nil,
        kind: LocationKind,
        note: String?,
        cleanability: Cleanability,
        source: AttributionSource,
        requirement: AppStateRequirement,
        owner: Owner?,
        inspectorID: String? = nil
    ) {
        let bytes = bytes ?? node.allocatedBytes
        guard bytes > 0 else { return }
        var cleanability = cleanability
        var note = note
        if cleanability == .protected || builder.protected.isProtected(node.path) {
            cleanability = .protected
        } else if cleanability == .cleanable, let blocked = BlockedContents.of(node) {
            // Same fail-closed rule as ProtectedPaths.protects(ancestorOf:), answered from the scan tree.
            cleanability = .protected
            note = blocked.note
        }
        let location = AttributedLocation(
            path: node.path, allocatedBytes: bytes, lastModified: node.newestModification,
            kind: kind, note: note, cleanability: cleanability, source: source, requirement: requirement)
        categories[category(location, owner: owner, inspectorID: inspectorID), default: []].append(location)
        if let owner {
            footprints[owner.key, default: FootprintAccumulator(owner: owner)]
                .add(location, owner: owner, inspectorID: inspectorID)
        }
    }

    /// Why a folder must not be removed as a whole.
    enum BlockedContents {
        case photosLibrary
        case unreadable

        var note: String {
            switch self {
            case .photosLibrary: "Contains a Photos library"
            case .unreadable: "Contains folders the app can't read"
            }
        }

        /// A Photos library or an unreadable folder anywhere below `node` (the folder itself
        /// included); a Photos library wins. The whole scan tree is in memory, so there is no depth
        /// limit here (unlike the validator's on-disk check).
        static func of(_ node: DirectorySummary) -> BlockedContents? {
            if node.isUnreadable { return .unreadable }
            if node.path.lowercased().hasSuffix(".photoslibrary") { return .photosLibrary }
            var unreadable = false
            for child in node.children {
                switch of(child) {
                case .photosLibrary: return .photosLibrary
                case .unreadable: unreadable = true
                case nil: break
                }
            }
            return unreadable ? .unreadable : nil
        }
    }

    func category(_ location: AttributedLocation, owner: Owner?, inspectorID: String?) -> StorageCategory {
        if let inspectorID, developerInspectorIDs.contains(inspectorID) { return .developerTools }
        switch location.kind {
        case .cache: return .caches
        case .logs: return .logs
        default: break
        }
        let key = PathKey(location.path)
        if key == trashKey || key.isInside(trashKey) { return .userFiles }
        let inHome = key.isInside(homeKey)
        if inHome {
            let relative = key.raw.dropFirst(homeKey.raw.count + 1)
            if relative.hasPrefix(".") { return .developerTools }
        }
        if appRootKeys.contains(where: { key == $0 || key.isInside($0) }) { return .appBundles }
        if userRootKeys.contains(where: { key == $0 || key.isInside($0) }) { return .userFiles }
        if owner != nil { return .appData }
        if !inHome && key != homeKey && systemRootKeys.contains(where: { key == $0 || key.isInside($0) }) { return .system }
        return .other
    }
}
