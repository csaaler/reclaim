import SwiftUI
import StorageCore

extension RiskLevel {
    var color: Color {
        switch self {
        case .cache: .green
        case .rebuildable: .orange
        case .userData: .red
        }
    }

    var shortTitle: String {
        switch self {
        case .cache: "Cache"
        case .rebuildable: "Rebuildable"
        case .userData: "Your data"
        }
    }
}

/// Risk level as emoji plus short label. The full meaning is in the help text.
struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text("\(risk.emoji) \(risk.shortTitle)")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.15), in: Capsule())
            .help(risk.title)
            .accessibilityLabel(risk.title)
    }
}

#Preview {
    VStack(alignment: .leading) {
        ForEach(RiskLevel.allCases, id: \.self) { RiskBadge(risk: $0) }
    }
    .padding()
}
