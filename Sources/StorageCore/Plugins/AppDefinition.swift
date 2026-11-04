/// One location an app definition owns, in `PathPattern` syntax.
public struct DefinedLocation: Sendable {
    public let pattern: String
    public let kind: LocationKind
    public let note: String

    public init(pattern: String, kind: LocationKind, note: String) {
        self.pattern = pattern
        self.kind = kind
        self.note = note
    }
}

/// A declarative description of an app's on-disk footprint.
public struct AppDefinition: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let bundleIDs: [String]
    public let processNames: [String]
    public let locations: [DefinedLocation]
    public let mustQuitBeforeCleaning: Bool
    public let sideEffectNote: String?

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        processNames: [String],
        locations: [DefinedLocation],
        mustQuitBeforeCleaning: Bool = true,
        sideEffectNote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.processNames = processNames
        self.locations = locations
        self.mustQuitBeforeCleaning = mustQuitBeforeCleaning
        self.sideEffectNote = sideEffectNote
    }
}
