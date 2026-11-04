import StorageCore

extension AppDefinition {
    static let cursor = AppDefinition.electron(
        id: "cursor",
        displayName: "Cursor",
        bundleIDs: ["com.todesktop.230313mzl4w4u92"],
        processNames: ["Cursor"],
        supportFolder: "Cursor"
    )
}
