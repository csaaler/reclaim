import SwiftUI
import StorageCore

/// The cleanup sheet: review, then progress, then results.
struct CleanupSheet: View {
    @Bindable var model: CleanupReviewModel
    let onClose: () -> Void
    let onDone: () -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .planning:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing the review…").foregroundStyle(.secondary)
                    Button("Cancel") {
                        model.cancelPlanning()
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .reviewing, .executing:
                ReviewView(model: model, onClose: onClose)
            case .finished:
                if let report = model.report {
                    ResultsView(report: report, cancelled: model.cancelRequested, onDone: onDone)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 480, idealHeight: 620)
        .interactiveDismissDisabled(model.phase == .executing)
    }
}
