import Foundation
import Observation
import StorageCore
import StorageDefinitions

/// Runs a scan: the disk scan (with the app index and volume totals alongside), then every
/// inspector's `discover`, sized from the finished scan tree, then `SnapshotBuilder`.
/// Nothing is persisted.
@MainActor @Observable
final class ScanCoordinator {
    enum Phase: Equatable {
        case scanning, inspecting, building

        var title: String {
            switch self {
            case .scanning: "Scanning…"
            case .inspecting: "Inspecting apps…"
            case .building: "Building overview…"
            }
        }
    }

    var snapshot: StorageSnapshot?
    var progress: ScanProgress?
    var isScanning = false
    private(set) var phase: Phase?
    /// Why the last scan produced no snapshot, if it did not finish.
    private(set) var errorMessage: String?
    /// True when the volume totals could not be read; the snapshot then carries zeros.
    private(set) var diskTotalsUnavailable = false
    /// Increases each time a scan starts; anything tied to the previous snapshot is stale.
    private(set) var generation = 0
    private(set) var lastScanDuration: Duration?
    private(set) var lastDiskScanDuration: Duration?
    /// The inspectors behind `snapshot`'s sections, by id.
    private(set) var inspectorDirectory: InspectorDirectory

    private let home: URL
    private var current: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.inspectorDirectory = InspectorSetup.current(home: home).directory
    }

    /// Scans once; does nothing when a snapshot exists or a scan is running.
    func start() async {
        guard snapshot == nil, current == nil else { return }
        await launch()
    }

    /// Cancels a running scan, if any, and starts a new one.
    func rescan() async {
        current?.cancel()
        await launch()
    }

    /// Stops the running scan; the UI shows it as cancelled.
    func cancel() {
        current?.cancel()
    }

    private func launch() async {
        generation += 1
        let mine = generation
        let task = Task { await self.run(generation: mine) }
        current = task
        await task.value
        if generation == mine { current = nil }
    }

    private func run(generation mine: Int) async {
        isScanning = true
        phase = .scanning
        snapshot = nil
        progress = nil
        errorMessage = nil
        diskTotalsUnavailable = false
        let started = ContinuousClock.now

        // A newer scan has replaced this one: it owns the state now.
        func superseded() -> Bool { generation != mine }
        func finish(error: String?) {
            guard !superseded() else { return }
            errorMessage = error
            isScanning = false
            phase = nil
            progress = nil
        }

        let home = self.home
        let setup = InspectorSetup.current(home: home)
        let inspectors = setup.inspectors

        // Without Full Disk Access, opening app containers or media libraries waits on a privacy prompt.
        let hasFullDiskAccess = FullDiskAccess.isGranted()
        let scanner = hasFullDiskAccess ? DiskScanner.dataVolume : DiskScanner.dataVolume.skippingPrivacyPromptedFolders()
        // The scanner calls back on its own threads, throttled to about 4 per second.
        async let scanResult = scanner.scan { [weak self] update in
            Task { @MainActor in
                guard let self, self.generation == mine, self.phase == .scanning else { return }
                self.progress = update
            }
        }
        async let appIndex = Self.installedApps(home: home)
        async let volumeStats = Self.volumeStats()

        let scan: ScanResult
        do {
            scan = try await scanResult
        } catch is CancellationError {
            _ = await (appIndex, volumeStats)
            finish(error: superseded() ? nil : "Scan cancelled.")
            return
        } catch {
            _ = await (appIndex, volumeStats)
            finish(error: "The disk scan failed: \(error)")
            return
        }
        let index = await appIndex
        let volume = await volumeStats
        guard !superseded() else { return }
        guard !Task.isCancelled else { finish(error: "Scan cancelled."); return }
        let diskScanDuration = ContinuousClock.now - started

        // Inspectors run after the scan so their sizing reads the tree instead of re-walking the disk.
        phase = .inspecting
        let context = InspectorContext(
            home: home,
            tools: setup.toolRunner(),
            sizer: ScanTreeSizer(scan: scan, fallback: ScannerSizer()))
        let (sections, claims) = await Self.inspect(inspectors, context: context)
        guard !superseded() else { return }
        guard !Task.isCancelled else { finish(error: "Scan cancelled."); return }

        phase = .building
        let bundleIDs = Dictionary(uniqueKeysWithValues: inspectors.map { ($0.id, $0.bundleIDs) })
        let builder = SnapshotBuilder(
            home: home, index: index, definitions: allDefinitions,
            protected: ProtectedPaths(home: home), codeRoots: setup.codeRoots, hasFullDiskAccess: hasFullDiskAccess)
        let stats = volume.stats ?? VolumeStats(totalBytes: 0, usedBytes: 0, availableBytes: 0, purgeableBytes: 0,
                                                systemVolumeBytes: 0, localSnapshotCount: 0)
        let built = await Task.detached(priority: .userInitiated) {
            builder.build(scan: scan, volume: stats, inspectorSections: sections,
                          claims: claims, inspectorBundleIDs: bundleIDs)
        }.value
        guard !superseded() else { return }

        inspectorDirectory = setup.directory
        snapshot = built
        diskTotalsUnavailable = volume.stats == nil
        lastDiskScanDuration = diskScanDuration
        lastScanDuration = ContinuousClock.now - started
        finish(error: nil)
    }

    /// Runs every inspector's `discover` and `claimedPaths` concurrently. A failure becomes the
    /// section's `unavailableReason`; sections keep the registry order.
    private nonisolated static func inspect(
        _ inspectors: [any Inspector],
        context: InspectorContext
    ) async -> ([InspectorSection], [String: [String]]) {
        await withTaskGroup(of: (Int, InspectorSection, [String]).self) { group in
            for (position, inspector) in inspectors.enumerated() {
                group.addTask {
                    async let claimed = inspector.claimedPaths(in: context)
                    let section: InspectorSection
                    do {
                        let items = try await inspector.discover(in: context)
                        section = InspectorSection(inspectorID: inspector.id, displayName: inspector.displayName,
                                                   items: items, unavailableReason: nil,
                                                   category: inspector.category)
                    } catch let unavailable as InspectorUnavailable {
                        section = InspectorSection(inspectorID: inspector.id, displayName: inspector.displayName,
                                                   items: [], unavailableReason: unavailable.reason,
                                                   category: inspector.category)
                    } catch {
                        section = InspectorSection(inspectorID: inspector.id, displayName: inspector.displayName,
                                                   items: [], unavailableReason: "\(error)",
                                                   category: inspector.category)
                    }
                    return (position, section, await claimed)
                }
            }
            var results: [(Int, InspectorSection, [String])] = []
            for await result in group { results.append(result) }
            results.sort { $0.0 < $1.0 }
            let claims = Dictionary(results.map { ($0.1.inspectorID, $0.2) }, uniquingKeysWith: +)
            return (results.map(\.1), claims)
        }
    }

    private nonisolated static func installedApps(home: URL) async -> AppIndex {
        AppIndex.scanInstalled(home: home)
    }

    private nonisolated static func volumeStats() async -> (stats: VolumeStats?, error: String?) {
        do {
            return (try VolumeInfo.stats(), nil)
        } catch {
            return (nil, "\(error)")
        }
    }
}
