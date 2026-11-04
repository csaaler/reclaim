import SwiftUI
import StorageCore

struct ByAppView: View {
    let apps: [AppFootprint]
    let inspectors: [InspectorSection]
    let onAdd: (CleanupCandidate) -> Void
    @State private var selection: String?

    private var scale: Int64 { apps.map(\.totalBytes).max() ?? 1 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                List(apps, selection: $selection) { app in
                    AppRow(app: app, scale: scale)
                        .tag(app.id)
                }
                legend
            }
            .frame(minWidth: 340)
            Divider()

            Group {
                if let app = apps.first(where: { $0.id == selection }) {
                    AppDetailView(app: app, inspectors: inspectors, onAdd: onAdd)
                } else {
                    ContentUnavailableView("Select an app", systemImage: "square.grid.2x2",
                                           description: Text("Pick an app to see where its bytes live."))
                }
            }
            .frame(minWidth: 380, idealWidth: 420, maxWidth: 460)
        }
        .onAppear { if selection == nil { selection = apps.first?.id } }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(RiskLevel.allCases, id: \.self) { risk in
                HStack(spacing: 4) {
                    Circle().fill(risk.color).frame(width: 8, height: 8)
                    Text(risk.shortTitle)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
}

private struct AppRow: View {
    let app: AppFootprint
    let scale: Int64

    var body: some View {
        HStack(spacing: 10) {
            Text(app.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 120, idealWidth: 170, alignment: .leading)
            if app.isOrphan {
                Text("Orphan")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("The app is no longer installed but left data behind")
            }
            RiskBar(footprint: app, scale: scale)
                .frame(minWidth: 60)
            ByteText(bytes: app.totalBytes)
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ByAppView(apps: StorageSnapshot.sample.apps, inspectors: StorageSnapshot.sample.inspectors, onAdd: { _ in }).frame(width: 900, height: 500)
}
