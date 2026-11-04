import SwiftUI
import StorageCore

struct DevToolsView: View {
    let sections: [InspectorSection]
    let onAdd: (CleanupCandidate) -> Void

    /// Only developer-tool inspectors; the others' items show under By App.
    private var devSections: [InspectorSection] {
        sections.filter { $0.category == .developerTools }
    }

    var body: some View {
        List {
            ForEach(devSections) { section in
                Section(section.displayName) {
                    if let reason = section.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if section.items.isEmpty {
                        Text("Nothing found").foregroundStyle(.secondary)
                    }
                    ForEach(section.items) { item in
                        ItemRow(item: item, onAdd: onAdd)
                    }
                }
            }
        }
        .overlay {
            if devSections.isEmpty {
                ContentUnavailableView("No developer tools found", systemImage: "hammer")
            }
        }
    }
}

struct ItemRow: View {
    let item: InspectorItem
    let onAdd: (CleanupCandidate) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(item.isActionable ? .primary : .secondary)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.whatYouLose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.isActionable {
                RiskBadge(risk: item.risk)
                ByteText(bytes: item.allocatedBytes).frame(width: 70, alignment: .trailing)
                Button(item.actionTitle) { onAdd(.inspectorItem(item)) }
                    .controlSize(.small)
            } else if item.allocatedBytes > 0 {
                ByteText(bytes: item.allocatedBytes).frame(width: 70, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DevToolsView(sections: StorageSnapshot.sample.inspectors, onAdd: { _ in }).frame(width: 800, height: 500)
}
