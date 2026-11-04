import StorageCore

extension AppDefinition {
    static let linear = AppDefinition.electron(
        id: "linear",
        displayName: "Linear",
        bundleIDs: ["com.linear"],
        processNames: ["Linear"],
        supportFolder: "Linear"
    )
}
