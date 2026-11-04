import SwiftUI
import StorageCore

/// What a list row can be added to the cleanup list as.
enum CleanupCandidate: Hashable, Identifiable {
    case location(AttributedLocation, appName: String)
    case inspectorItem(InspectorItem)

    var id: String {
        switch self {
        case .location(let loc, _): "location:\(loc.path)"
        case .inspectorItem(let item): "item:\(item.inspectorID):\(item.id)"
        }
    }

    /// Identity is the path/item only, so the same location added from two views counts once.
    static func == (lhs: CleanupCandidate, rhs: CleanupCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var bytes: Int64 {
        switch self {
        case .location(let loc, _): loc.allocatedBytes
        case .inspectorItem(let item): item.allocatedBytes
        }
    }
}

struct AppDetailView: View {
    let app: AppFootprint
    let inspectors: [InspectorSection]
    let onAdd: (CleanupCandidate) -> Void

    private var sections: [InspectorSection] {
        inspectors.filter { app.inspectorIDs.contains($0.inspectorID) }
    }

    var body: some View {
        List {
            Section {
                header
            }
            Section("Locations") {
                ForEach(app.locations) { loc in
                    LocationRow(location: loc, appName: app.displayName, onAdd: onAdd)
                }
            }
            ForEach(sections) { section in
                Section("\(section.displayName) inspector") {
                    if let reason = section.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else if section.items.isEmpty {
                        Text("Nothing found").foregroundStyle(.secondary)
                    }
                    ForEach(section.items) { item in
                        ItemRow(item: item, onAdd: onAdd)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(app.displayName).font(.title2.bold())
                if app.isOrphan { Text("Orphan").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                ByteText(bytes: app.totalBytes).font(.title3)
            }
            if !app.isInstalled {
                Text("Not installed").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LocationRow: View {
    let location: AttributedLocation
    let appName: String
    let onAdd: (CleanupCandidate) -> Void
    @Environment(\.inspectorDirectory) private var inspectorDirectory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(abbreviatedPath(location.path))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(location.path)
                Spacer()
                RiskBadge(risk: location.risk)
                ByteText(bytes: location.allocatedBytes)
                    .frame(width: 70, alignment: .trailing)
            }
            HStack {
                if let date = location.lastModified {
                    Text("Modified \(date.formatted(.relative(presentation: .named)))")
                } else {
                    Text("Modified unknown")
                }
                if let note = location.note { Text("· \(note)") }
                Spacer()
                action
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") { reveal(location.path) }
        }
    }

    @ViewBuilder
    private var action: some View {
        if location.isCleanable {
            Button("Add to cleanup list") { onAdd(.location(location, appName: appName)) }
                .controlSize(.small)
        } else if let reason = location.cleanabilityReason(in: inspectorDirectory) {
            Label(reason, systemImage: location.cleanability == .protected ? "lock" : "eye")
        }
    }
}

func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

#Preview {
    AppDetailView(app: StorageSnapshot.sample.apps[0], inspectors: StorageSnapshot.sample.inspectors, onAdd: { _ in }).frame(width: 560, height: 480)
}
