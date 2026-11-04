import Foundation

/// Turns a raw scan, inspector results and attribution data into the `StorageSnapshot` the UI renders.
///
/// The builder walks the scan tree and stops descending at the first node that is an inspector claim,
/// a definition location, a location-rule match or an app folder under `Application Support`,
/// `Containers` or `Group Containers` (precedence: claims > definitions > rules > generic attribution).
/// Every byte of the scan ends up in exactly one `AttributedLocation`, so category totals add up to the
/// scanned total. A folder that has separately listed descendants is listed once more for its
/// remaining bytes; such a remainder is never cleanable, because cleaning its path would also remove
/// the separately listed folders.
///
/// The walk only descends into ancestors of interesting paths, matched against a segment trie built
/// once per build, so its cost grows with the number of candidate locations, not with the scan size.
/// `Attributor.attribute(_:)` is called once per app folder and memoized.
///
/// The walk lives in `BuildRun`, the trie in `PathTrie.swift`.
public struct SnapshotBuilder: Sendable {
    public let home: URL
    public let index: AppIndex
    public let definitions: [AppDefinition]
    public let protected: ProtectedPaths
    /// Project folders in `PathPattern` syntax (`~/git`); their children are user files.
    public let codeRoots: [String]
    /// Whether the scan ran with Full Disk Access; without it the unreadable bucket says how to fix it.
    public let hasFullDiskAccess: Bool

    /// Top-level folders in home whose children are the user's own files.
    public static let userFolders = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"]

    public init(
        home: URL, index: AppIndex, definitions: [AppDefinition], protected: ProtectedPaths,
        codeRoots: [String] = [], hasFullDiskAccess: Bool = false
    ) {
        self.home = home
        self.index = index
        self.definitions = definitions
        self.protected = protected
        self.codeRoots = codeRoots
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// - Parameters:
    ///   - claims: inspector ID → expanded claimed paths.
    ///   - inspectorBundleIDs: inspector ID → the inspector's `bundleIDs`, used to put its claims under
    ///     the right app in By App. Inspectors without bundle IDs get a footprint of their own.
    public func build(
        scan: ScanResult,
        volume: VolumeStats,
        inspectorSections: [InspectorSection],
        claims: [String: [String]],
        inspectorBundleIDs: [String: [String]] = [:]
    ) -> StorageSnapshot {
        var run = BuildRun(builder: self, sections: inspectorSections, claims: claims,
                           inspectorBundleIDs: inspectorBundleIDs, largeFiles: scan.largeFiles,
                           unreadablePaths: scan.unreadablePaths)
        run.walk(scan.root)
        let (apps, categories) = run.assemble()
        return StorageSnapshot(
            volume: volume,
            scan: scan,
            apps: apps,
            categories: categories,
            inspectors: inspectorSections,
            unaccounted: Self.unaccounted(scan: scan, volume: volume, hasFullDiskAccess: hasFullDiskAccess))
    }

    /// Prefix of the unreadable bucket's title; the title carries the folder count. Prefer
    /// `UnaccountedBucket.kind` to recognise the bucket.
    public static let unreadableTitlePrefix = "Unreadable"

    static func unaccounted(scan: ScanResult, volume: VolumeStats, hasFullDiskAccess: Bool) -> [UnaccountedBucket] {
        let scanned = scan.root.allocatedBytes
        let unreadable = scan.unreadablePaths.count
        let snapshots = volume.localSnapshotCount
        // Purgeable space is subtracted too so the buckets add up to the used space.
        let notExplained = max(0, volume.usedBytes - scanned - volume.systemVolumeBytes - volume.purgeableBytes)
        let folders = "\(unreadable) \(unreadable == 1 ? "folder" : "folders")"
        return [
            UnaccountedBucket(
                kind: .unreadable,
                title: hasFullDiskAccess ? "\(unreadableTitlePrefix): \(folders)"
                    : "\(unreadableTitlePrefix) (grant Full Disk Access): \(folders)",
                bytes: 0,
                explanation: "\(folders) could not be read, so their size is unknown and counted under “Not explained”. "
                    + (hasFullDiskAccess ? "macOS protects them even from apps with Full Disk Access."
                       : "Grant Full Disk Access to include them.")),
            UnaccountedBucket(
                kind: .systemVolume, title: "macOS system volume", bytes: volume.systemVolumeBytes,
                explanation: "The read-only macOS system volume. It is managed by macOS and cannot be cleaned."),
            UnaccountedBucket(
                kind: .purgeable, title: "Purgeable / local snapshots", bytes: volume.purgeableBytes,
                explanation: "Space macOS can free on its own, including \(snapshots) local Time Machine \(snapshots == 1 ? "snapshot" : "snapshots"). macOS removes them when space runs low."),
            UnaccountedBucket(
                kind: .notExplained, title: "Not explained", bytes: notExplained,
                explanation: "Used space the scan did not find: unreadable folders, other volumes in the container (VM, Preboot, Recovery) and space in use by deleted-but-open files."),
        ]
    }
}
