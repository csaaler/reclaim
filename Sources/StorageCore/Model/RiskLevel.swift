/// How costly it is to lose an item. Shown everywhere in the UI.
public enum RiskLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    case cache = 0
    case rebuildable = 1
    case userData = 2

    public var emoji: String {
        switch self {
        case .cache: "🟢"
        case .rebuildable: "🟡"
        case .userData: "🔴"
        }
    }

    public var title: String {
        switch self {
        case .cache: "Rebuildable cache"
        case .rebuildable: "Costly to rebuild"
        case .userData: "Your data or config"
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
