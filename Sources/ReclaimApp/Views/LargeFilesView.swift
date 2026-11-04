import SwiftUI
import StorageCore

struct LargeFilesView: View {
    let files: [LargeFile]
    /// Snapshot locations by path. A large file is addable only when it is a cleanable location
    /// (a 🔴 file directly in a user or code folder).
    var locations: [String: AttributedLocation] = [:]
    var onAdd: (CleanupCandidate) -> Void = { _ in }

    static let viewOnlyReason = "View only: only large files directly in Downloads, Desktop, Documents, Movies, Music, Pictures or a code folder can be cleaned"

    /// Every snapshot location, keyed by path.
    static func locationIndex(_ snapshot: StorageSnapshot) -> [String: AttributedLocation] {
        Dictionary(snapshot.categories.flatMap(\.locations).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }
    @Environment(\.inspectorDirectory) private var inspectorDirectory
    @State private var sortOrder = [KeyPathComparator(\LargeFile.allocatedBytes, order: .reverse)]
    @State private var selection: LargeFile.ID?

    var body: some View {
        Table(files.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.path) { file in
                VStack(alignment: .leading, spacing: 0) {
                    Text((file.path as NSString).lastPathComponent).lineLimit(1)
                    Text(abbreviatedPath((file.path as NSString).deletingLastPathComponent))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            TableColumn("Size", value: \.allocatedBytes) { file in
                ByteText(bytes: file.allocatedBytes)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modified) { file in
                Text(file.modified.formatted(.relative(presentation: .named)))
            }
            .width(min: 90, ideal: 130)
            TableColumn("Cleanup") { file in
                if let location = locations[file.path], location.isCleanable {
                    HStack(spacing: 6) {
                        RiskBadge(risk: location.risk)
                        Button("Add to cleanup list") { onAdd(.location(location, appName: "")) }
                            .controlSize(.small)
                    }
                } else {
                    let reason = locations[file.path]?.cleanabilityReason(in: inspectorDirectory) ?? Self.viewOnlyReason
                    Text(reason)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(reason)
                }
            }
            .width(min: 160, ideal: 260)
        }
        .contextMenu(forSelectionType: LargeFile.ID.self) { ids in
            if let path = ids.first {
                Button("Reveal in Finder") { reveal(path) }
            }
        }
    }
}

#Preview {
    LargeFilesView(files: StorageSnapshot.sample.scan.largeFiles).frame(width: 800, height: 400)
}
