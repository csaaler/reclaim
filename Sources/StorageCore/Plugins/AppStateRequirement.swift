/// What state the owning app must be in before a cleanup step may run.
public enum AppStateRequirement: Sendable, Hashable, Codable {
    case mustBeQuit(bundleIDs: [String], processNames: [String])
    case mustBeRunning(bundleIDs: [String], processNames: [String], reason: String)
    case none
}
