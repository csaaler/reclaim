import SwiftUI
import StorageCore

extension StorageCategory {
    var title: String {
        switch self {
        case .caches: "Caches"
        case .appData: "App data"
        case .developerTools: "Developer tools"
        case .logs: "Logs"
        case .appBundles: "App bundles"
        case .userFiles: "User files"
        case .system: "System"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .caches: "tray.full"
        case .appData: "externaldrive"
        case .developerTools: "hammer"
        case .logs: "doc.text"
        case .appBundles: "app"
        case .userFiles: "person.crop.square"
        case .system: "gearshape"
        case .other: "ellipsis.circle"
        }
    }
}

struct ByCategoryView: View {
    let categories: [CategoryTotal]
    let onAdd: (CleanupCandidate) -> Void
    @Environment(\.inspectorDirectory) private var inspectorDirectory

    private var sorted: [CategoryTotal] { categories.sorted { $0.bytes > $1.bytes } }
    private var scale: Int64 { sorted.first?.bytes ?? 1 }

    var body: some View {
        List {
            ForEach(sorted) { total in
                if total.locations.isEmpty {
                    row(total)
                } else {
                    DisclosureGroup {
                        ForEach(total.locations.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(25)) { loc in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(abbreviatedPath(loc.path))
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(loc.path)
                                    if let reason = loc.cleanabilityReason(in: inspectorDirectory) {
                                        Text(reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                RiskBadge(risk: loc.risk)
                                ByteText(bytes: loc.allocatedBytes).frame(width: 70, alignment: .trailing)
                                if loc.isCleanable {
                                    Button("Add") { onAdd(.location(loc, appName: total.category.title)) }
                                        .controlSize(.small)
                                }
                            }
                            .font(.callout)
                        }
                    } label: {
                        row(total)
                    }
                }
            }
        }
    }

    private func row(_ total: CategoryTotal) -> some View {
        HStack(spacing: 10) {
            Label(total.category.title, systemImage: total.category.symbol)
                .frame(width: 170, alignment: .leading)
            ProgressView(value: Double(total.bytes), total: Double(max(scale, 1)))
                .progressViewStyle(.linear)
            ByteText(bytes: total.bytes).frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ByCategoryView(categories: StorageSnapshot.sample.categories, onAdd: { _ in }).frame(width: 700, height: 450)
}
