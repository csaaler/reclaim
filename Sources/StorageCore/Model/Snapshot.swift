import Foundation

public enum Cleanability: Sendable, Hashable {
    case cleanable
    case viewOnly(reason: String)
    case protected
    case claimed(inspectorID: String)
}

public enum AttributionSource: Sendable, Hashable {
    case inspector(String)
    case definition(String)
    case locationRule
    case generic
    case unattributed
}

public struct AttributedLocation: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let allocatedBytes: Int64
    public let lastModified: Date?
    public let kind: LocationKind
    public let note: String?
    public let cleanability: Cleanability
    public let source: AttributionSource
    public let requirement: AppStateRequirement
    public var risk: RiskLevel { kind.risk }

    public init(
        path: String,
        allocatedBytes: Int64,
        lastModified: Date?,
        kind: LocationKind,
        note: String?,
        cleanability: Cleanability,
        source: AttributionSource,
        requirement: AppStateRequirement
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.lastModified = lastModified
        self.kind = kind
        self.note = note
        self.cleanability = cleanability
        self.source = source
        self.requirement = requirement
    }
}

public struct AppFootprint: Sendable, Identifiable {
    /// Definition id, bundle id, or folder name.
    public let id: String
    public let displayName: String
    public let isInstalled: Bool
    public let isOrphan: Bool
    /// Sorted by size descending.
    public let locations: [AttributedLocation]
    public let inspectorIDs: [String]

    public var totalBytes: Int64 { locations.reduce(0) { $0 + $1.allocatedBytes } }

    public func bytes(for risk: RiskLevel) -> Int64 {
        locations.filter { $0.risk == risk }.reduce(0) { $0 + $1.allocatedBytes }
    }

    public init(
        id: String,
        displayName: String,
        isInstalled: Bool,
        isOrphan: Bool,
        locations: [AttributedLocation],
        inspectorIDs: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.isInstalled = isInstalled
        self.isOrphan = isOrphan
        self.locations = locations
        self.inspectorIDs = inspectorIDs
    }
}

public struct CategoryTotal: Sendable, Identifiable {
    public let category: StorageCategory
    public let bytes: Int64
    public let locations: [AttributedLocation]
    public var id: StorageCategory { category }

    public init(category: StorageCategory, bytes: Int64, locations: [AttributedLocation]) {
        self.category = category
        self.bytes = bytes
        self.locations = locations
    }
}

/// Used space that no scanned folder explains, shown under the categories.
public struct UnaccountedBucket: Sendable, Identifiable {
    public enum Kind: Sendable, Hashable, Codable {
        /// Folders the scan could not read; their size is unknown, so `bytes` is 0.
        case unreadable
        /// The read-only macOS system volume.
        case systemVolume
        /// Space macOS can free on its own, including local Time Machine snapshots.
        case purgeable
        /// Used space the scan did not find anywhere else.
        case notExplained
    }

    public let kind: Kind
    public let title: String
    public let bytes: Int64
    public let explanation: String
    public var id: String { title }

    public init(kind: Kind, title: String, bytes: Int64, explanation: String) {
        self.kind = kind
        self.title = title
        self.bytes = bytes
        self.explanation = explanation
    }
}

public struct InspectorSection: Sendable, Identifiable {
    public let inspectorID: String
    public let displayName: String
    public let items: [InspectorItem]
    public let unavailableReason: String?
    /// The inspector's `category`. `.developerTools` puts its claimed locations under
    /// "Developer tools" in By Category; otherwise they are classified like any other location.
    public let category: StorageCategory?
    public var id: String { inspectorID }

    public init(
        inspectorID: String, displayName: String, items: [InspectorItem], unavailableReason: String?,
        category: StorageCategory? = nil
    ) {
        self.inspectorID = inspectorID
        self.displayName = displayName
        self.items = items
        self.unavailableReason = unavailableReason
        self.category = category
    }
}

/// Everything the UI renders after a scan.
public struct StorageSnapshot: Sendable {
    public let volume: VolumeStats
    public let scan: ScanResult
    public let apps: [AppFootprint]
    public let categories: [CategoryTotal]
    public let inspectors: [InspectorSection]
    public let unaccounted: [UnaccountedBucket]

    public init(
        volume: VolumeStats,
        scan: ScanResult,
        apps: [AppFootprint],
        categories: [CategoryTotal],
        inspectors: [InspectorSection],
        unaccounted: [UnaccountedBucket]
    ) {
        self.volume = volume
        self.scan = scan
        self.apps = apps
        self.categories = categories
        self.inspectors = inspectors
        self.unaccounted = unaccounted
    }
}
