import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case byApp = "By App"
    case byCategory = "By Category"
    case devTools = "Dev Tools"
    case explorer = "Explorer"
    case largeFiles = "Large & Old Files"
    case history = "History"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .byApp: "square.grid.2x2"
        case .byCategory: "tag"
        case .devTools: "hammer"
        case .explorer: "folder"
        case .largeFiles: "doc.badge.clock"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            Label(item.rawValue, systemImage: item.symbol)
                .tag(item)
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
    }
}

#Preview {
    SidebarView(selection: .constant(.byApp)).frame(width: 200, height: 300)
}
