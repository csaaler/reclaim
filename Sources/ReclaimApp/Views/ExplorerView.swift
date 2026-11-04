import SwiftUI
import StorageCore

private extension DirectorySummary {
    var outlineChildren: [DirectorySummary]? { children.isEmpty ? nil : children }
    var displayName: String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

struct ExplorerView: View {
    let root: DirectorySummary

    var body: some View {
        List {
            OutlineGroup(root.children, children: \.outlineChildren) { node in
                ExplorerRow(node: node, total: max(root.allocatedBytes, 1))
            }
        }
    }
}

private struct ExplorerRow: View {
    let node: DirectorySummary
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            Label(node.displayName, systemImage: node.isUnreadable ? "lock.fill" : "folder")
                .lineLimit(1)
                .frame(minWidth: 160, alignment: .leading)
            if node.isUnreadable {
                Text("Unreadable without Full Disk Access")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            ProgressView(value: Double(node.allocatedBytes), total: Double(total))
                .frame(width: 120)
            ByteText(bytes: node.allocatedBytes).frame(width: 70, alignment: .trailing)
            if let date = node.newestModification {
                Text(date.formatted(.relative(presentation: .numeric)))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            Button {
                reveal(node.path)
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .accessibilityElement(children: .combine)
        .contextMenu { Button("Reveal in Finder") { reveal(node.path) } }
    }
}

#Preview {
    ExplorerView(root: StorageSnapshot.sample.scan.root).frame(width: 800, height: 500)
}
