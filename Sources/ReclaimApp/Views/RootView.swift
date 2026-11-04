import AppKit
import SwiftUI
import StorageCore

struct RootView: View {
    let snapshot: StorageSnapshot?
    let progress: ScanProgress?
    let history: [LogEntry]
    /// Why the cleanup log could not be read; shown instead of an (incorrectly) empty History.
    let historyError: String?
    let onAddToCleanup: (CleanupCandidate) -> Void
    let cleanupCount: Int
    let cleanupBytes: Int64
    let onOpenCleanup: () -> Void
    let onRescan: () -> Void
    /// What the running scan is doing ("Scanning…"), shown while there is no snapshot.
    let phase: String?
    /// Why the last scan did not produce a snapshot.
    let errorMessage: String?
    /// The volume totals could not be read; the snapshot's volume numbers are zeros.
    let diskTotalsUnavailable: Bool

    @State private var selection: SidebarItem? = .byApp
    /// Owned by the app so its probes run once, not on every view update. Nil in previews, which
    /// then behave as if access were granted.
    let fullDiskAccess: FullDiskAccessMonitor?

    init(
        snapshot: StorageSnapshot?,
        progress: ScanProgress?,
        history: [LogEntry],
        historyError: String? = nil,
        onAddToCleanup: @escaping (CleanupCandidate) -> Void,
        cleanupCount: Int,
        cleanupBytes: Int64,
        onOpenCleanup: @escaping () -> Void,
        onRescan: @escaping () -> Void,
        phase: String? = nil,
        errorMessage: String? = nil,
        diskTotalsUnavailable: Bool = false,
        fullDiskAccess: FullDiskAccessMonitor? = nil
    ) {
        self.fullDiskAccess = fullDiskAccess
        self.phase = phase
        self.errorMessage = errorMessage
        self.diskTotalsUnavailable = diskTotalsUnavailable
        self.snapshot = snapshot
        self.progress = progress
        self.history = history
        self.historyError = historyError
        // Only actionable candidates may reach the cleanup list.
        self.onAddToCleanup = { candidate in
            switch candidate {
            case .location(let loc, _): guard loc.isCleanable else { return }
            case .inspectorItem(let item): guard item.isActionable else { return }
            }
            onAddToCleanup(candidate)
        }
        self.cleanupCount = cleanupCount
        self.cleanupBytes = cleanupBytes
        self.onOpenCleanup = onOpenCleanup
        self.onRescan = onRescan
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detail
                .navigationTitle(selection?.rawValue ?? "Reclaim")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let snapshot, selection == .byApp || selection == .byCategory {
                        ReconciliationFooter(snapshot: snapshot, diskTotalsUnavailable: diskTotalsUnavailable)
                    }
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if diskTotalsUnavailable && snapshot != nil {
                    Text("Disk totals unavailable")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                } else if let volume = snapshot?.volume {
                    Text("\(ByteText.string(volume.usedBytes)) used · \(ByteText.string(volume.availableBytes)) free")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: onOpenCleanup) {
                    Label(cleanupCount == 0 ? "Cleanup list (0)" : "Cleanup list (\(cleanupCount)) · \(ByteText.string(cleanupBytes))", systemImage: "cart")
                }
                .labelStyle(.titleAndIcon)
                .help("Review the cleanup list")
                Button(action: onRescan) {
                    Label(snapshot == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!hasFullDiskAccess || phase != nil)
                .help(hasFullDiskAccess ? "Scan again (Command-R)" : "Turn on Full Disk Access to scan")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fullDiskAccess?.refresh()
        }
        .frame(minWidth: 1040, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        if let snapshot {
            switch selection ?? .byApp {
            case .byApp: ByAppView(apps: snapshot.apps, inspectors: snapshot.inspectors, onAdd: onAddToCleanup)
            case .byCategory: ByCategoryView(categories: snapshot.categories, onAdd: onAddToCleanup)
            case .devTools: DevToolsView(sections: snapshot.inspectors, onAdd: onAddToCleanup)
            case .explorer: ExplorerView(root: snapshot.scan.root)
            case .largeFiles:
                LargeFilesView(files: snapshot.scan.largeFiles,
                               locations: LargeFilesView.locationIndex(snapshot), onAdd: onAddToCleanup)
            case .history: historyView
            }
        } else if selection == .history {
            historyView
        } else if let progress {
            ScanningView(progress: progress, phase: phase)
        } else if let phase {
            VStack(spacing: 10) {
                ProgressView()
                Text(phase).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            StartScanView(
                isGranted: hasFullDiskAccess,
                isAdHocSigned: fullDiskAccess?.isAdHocSigned ?? false,
                isRelaunching: fullDiskAccess?.isRelaunching ?? false,
                relaunchError: fullDiskAccess?.relaunchError,
                errorMessage: errorMessage,
                onOpenSettings: { FullDiskAccess.openSettings() },
                onQuitAndReopen: { fullDiskAccess?.quitAndReopen() },
                onStart: onRescan)
        }
    }

    private var hasFullDiskAccess: Bool { fullDiskAccess?.isGranted ?? true }
}

extension RootView {
    @ViewBuilder fileprivate var historyView: some View {
        if let historyError {
            ContentUnavailableView {
                Label("History couldn't be read: \(historyError)", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Cleanups are still logged. The log is at ~/Library/Application Support/Reclaim/cleanup-log.jsonl.")
            }
        } else {
            HistoryView(entries: history)
        }
    }
}

/// Progressive top-level list while the first scan runs.
private struct ScanningView: View {
    let progress: ScanProgress
    let phase: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if let phase, phase != "Scanning…" {
                    Text(phase).lineLimit(1)
                } else {
                    Text("Scanning \(progress.currentPath)")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("\(ByteText.string(progress.bytesSoFar)) · \(progress.filesSoFar.formatted()) files")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            let top = progress.completedTopLevel.sorted { $0.allocatedBytes > $1.allocatedBytes }
            List(top) { dir in
                HStack {
                    Label((dir.path as NSString).lastPathComponent, systemImage: "folder")
                    Spacer()
                    ByteText(bytes: dir.allocatedBytes).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Used vs. accounted-for space, with each unaccounted bucket named, so totals reconcile.
private struct ReconciliationFooter: View {
    let snapshot: StorageSnapshot
    let diskTotalsUnavailable: Bool

    var body: some View {
        if diskTotalsUnavailable {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text("Disk totals unavailable · scanned \(ByteText.string(snapshot.scan.root.allocatedBytes))")
                    .fontWeight(.medium)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .background(.bar)
        } else {
            totals
        }
    }

    @ViewBuilder private var totals: some View {
        let unaccounted = snapshot.unaccounted.reduce(0) { $0 + $1.bytes }
        let accounted = snapshot.volume.usedBytes - unaccounted
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 14) {
                Text("Disk used \(ByteText.string(snapshot.volume.usedBytes)) = scanned \(ByteText.string(accounted)) + unaccounted \(ByteText.string(unaccounted))")
                    .fontWeight(.medium)
                Spacer()
            }
            HStack(spacing: 14) {
                ForEach(snapshot.unaccounted) { bucket in
                    // The unreadable bucket's size is unknown; its title carries the folder count.
                    Text(bucket.kind == .unreadable
                         ? bucket.title : "\(bucket.title) \(ByteText.string(bucket.bytes))")
                        .help(bucket.explanation)
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Sample") {
    RootView(snapshot: .sample, progress: nil, history: [], onAddToCleanup: { _ in },
             cleanupCount: 3, cleanupBytes: 22_000_000_000, onOpenCleanup: {}, onRescan: {})
}

#Preview("Scanning") {
    let top = Array(StorageSnapshot.sample.scan.root.children.prefix(4))
    RootView(snapshot: nil,
             progress: ScanProgress(currentPath: "/Users/sample/Library", bytesSoFar: 52_000_000_000, filesSoFar: 410_000, completedTopLevel: top),
             history: [], onAddToCleanup: { _ in }, cleanupCount: 0, cleanupBytes: 0, onOpenCleanup: {}, onRescan: {})
}
