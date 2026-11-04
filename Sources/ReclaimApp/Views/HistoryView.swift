import SwiftUI
import StorageCore

struct HistoryView: View {
    let entries: [LogEntry]

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView("No cleanups yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Everything you remove is logged here."))
        } else {
            List(entries.sorted { $0.date > $1.date }) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    RiskBadge(risk: entry.risk)
                    outcome(entry.outcome)
                        .frame(width: 230, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func outcome(_ outcome: StepOutcome) -> some View {
        switch outcome {
        case .freed(let bytes):
            Label("Freed \(ByteText.string(bytes))", systemImage: "checkmark.circle")
        case .trashed(let bytes, _):
            Label("Moved to Trash \(ByteText.string(bytes)) (frees space after emptying Trash)", systemImage: "trash")
                .font(.caption)
        case .edited:
            Label("Edited — backup moved to Trash", systemImage: "doc.badge.gearshape")
                .font(.caption)
        case .skipped(let reason):
            Label("Skipped: \(reason)", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label("Failed: \(message)", systemImage: "xmark.octagon").foregroundStyle(.red)
        }
    }
}

#Preview {
    let entries = [
        LogEntry(id: UUID(), date: .now, title: "Chrome cache", action: .delete(path: "/x", expectedFileID: nil), risk: .cache, outcome: .freed(bytes: 4_000_000_000)),
        LogEntry(id: UUID(), date: .now.addingTimeInterval(-3600), title: "Profile 11", action: .trash(path: "/y", expectedFileID: nil), risk: .userData, outcome: .trashed(bytes: 5_100_000_000, trashPath: "/t")),
    ]
    HistoryView(entries: entries).frame(width: 800, height: 300)
}
