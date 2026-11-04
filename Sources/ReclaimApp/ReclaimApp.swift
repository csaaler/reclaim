import SwiftUI
import StorageCore

@main
struct ReclaimApp: App {
    @State private var coordinator = ScanCoordinator()
    @State private var fullDiskAccess = FullDiskAccessMonitor()
    @State private var cleanupList = CleanupList()
    @State private var services = CleanupServices.live()
    /// Non-nil while the cleanup sheet is open.
    @State private var review: CleanupReviewModel?
    @State private var history: [LogEntry] = []
    @State private var historyError: String?

    var body: some Scene {
        WindowGroup("Reclaim") {
            RootView(
                snapshot: coordinator.snapshot,
                progress: coordinator.progress,
                history: history,
                historyError: historyError,
                onAddToCleanup: { cleanupList.add($0) },
                cleanupCount: cleanupList.candidates.count,
                cleanupBytes: cleanupList.totalBytes,
                onOpenCleanup: { openReview() },
                onRescan: { Task { await coordinator.scan() } },
                phase: coordinator.isScanning ? coordinator.phase?.title : nil,
                errorMessage: coordinator.errorMessage,
                diskTotalsUnavailable: coordinator.diskTotalsUnavailable,
                fullDiskAccess: fullDiskAccess
            )
            .environment(\.inspectorDirectory, coordinator.inspectorDirectory)
            .task { reloadHistory() }
            // Candidates belong to the snapshot they were picked from.
            .onChange(of: coordinator.generation) { cleanupList.removeAll() }
            .onChange(of: review?.phase) { _, phase in
                if phase == .finished { reloadHistory() }
            }
            .sheet(isPresented: Binding(
                get: { review != nil },
                set: { isPresented in
                    guard !isPresented, let current = review else { return }
                    // Closing the results any other way counts as Done: the scan is stale now.
                    if current.phase == .finished { finishCleanup() } else if current.phase != .executing { closeReview() }
                }
            )) {
                if let review {
                    CleanupSheet(model: review, onClose: closeReview, onDone: finishCleanup)
                }
            }
        }
        .defaultSize(width: 1180, height: 720)
    }

    @discardableResult
    private func openReview() -> CleanupReviewModel? {
        guard review == nil else { return review }
        let model = CleanupReviewModel(services: services, list: cleanupList)
        review = model
        model.start()
        return model
    }

    /// Closes the review without running anything; planning in progress is cancelled.
    private func closeReview() {
        review?.cancelPlanning()
        review = nil
    }

    /// Results "Done": the disk changed, so rescan and start a fresh list.
    private func finishCleanup() {
        review = nil
        cleanupList.removeAll()
        reloadHistory()
        Task { await coordinator.scan() }
    }

    private func reloadHistory() {
        do {
            history = try services.readHistory()
            historyError = nil
        } catch {
            history = []
            historyError = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
