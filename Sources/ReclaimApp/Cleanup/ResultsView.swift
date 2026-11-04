import SwiftUI
import StorageCore

/// What the engine did, one row per step, then freed vs. trashed totals.
struct ResultsView: View {
    let report: CleanupReport
    let cancelled: Bool
    let onDone: () -> Void

    private var rows: [(index: Int, step: CleanupStep, outcome: StepOutcome)] {
        report.results.enumerated().map { (index: $0.offset, step: $0.element.step, outcome: $0.element.outcome) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cleanup results").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(16)
            Divider()
            if !report.logFailures.isEmpty {
                let count = report.logFailures.count
                Label("\(count) log \(count == 1 ? "entry" : "entries") couldn't be written", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(report.logFailures.joined(separator: "\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.1))
                Divider()
            }
            List(rows, id: \.index) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.step.title)
                        Text(row.step.target)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.step.fullTarget)
                    }
                    Spacer()
                    RiskBadge(risk: row.step.risk)
                    OutcomeLabel(outcome: row.outcome)
                        .frame(width: 300, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Freed \(ByteText.string(report.freedBytes)) · Moved to Trash \(ByteText.string(report.trashedBytes)) (frees space after emptying Trash)")
                        .font(.headline)
                        .monospacedDigit()
                    if cancelled {
                        Text("Stopped: steps that had not started were skipped. Finished steps are not undone.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .help("Rescan the disk and clear the cleanup list")
            }
            .padding(16)
        }
    }
}

struct OutcomeLabel: View {
    let outcome: StepOutcome

    var body: some View {
        switch outcome {
        case .freed(let bytes):
            Label("Freed \(ByteText.string(bytes))", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .trashed(let bytes, let trashPath):
            Label("Moved to Trash \(ByteText.string(bytes))", systemImage: "trash")
                .help("Frees space after emptying Trash. Now at \(trashPath)")
        case .edited(let backup):
            Label("Edited — backup moved to Trash", systemImage: "doc.badge.gearshape")
                .help("Backup: \(backup)")
        case .skipped(let reason):
            Label("Skipped: \(reason)", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(reason)
        case .failed(let message):
            Label("Failed: \(message)", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(message)
        }
    }
}

#Preview {
    let step = CleanupStep(title: "Delete ~/Library/Caches/x", risk: .cache, estimatedBytes: 1_000_000, requirement: .none,
                           action: .delete(path: "/Users/sample/Library/Caches/x", expectedFileID: nil))
    let red = CleanupStep(title: "Move ~/Downloads/a.bin to Trash", risk: .userData, estimatedBytes: 2_000_000, requirement: .none,
                          action: .trash(path: "/Users/sample/Downloads/a.bin", expectedFileID: nil))
    ResultsView(report: CleanupReport(results: [(step, .freed(bytes: 1_000_000)),
                                               (red, .trashed(bytes: 2_000_000, trashPath: "/Users/sample/.Trash/a.bin"))],
                                     logFailures: ["x"]),
                cancelled: false, onDone: {})
        .frame(width: 860, height: 400)
}
