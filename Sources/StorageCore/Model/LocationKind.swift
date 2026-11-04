/// What a location on disk holds.
public enum LocationKind: String, Sendable, Codable {
    case cache, logs, rebuildable, userData, config

    public var risk: RiskLevel {
        switch self {
        case .cache, .logs: .cache
        case .rebuildable: .rebuildable
        case .userData, .config: .userData
        }
    }
}
