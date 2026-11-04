import StorageCore

extension AppDefinition {
    static let notion = AppDefinition.electron(
        id: "notion",
        displayName: "Notion",
        bundleIDs: ["notion.id"],
        processNames: ["Notion"],
        supportFolder: "Notion"
    )
}
