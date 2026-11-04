import StorageCore

extension AppDefinition {
    static let slack = AppDefinition.electron(
        id: "slack",
        displayName: "Slack",
        bundleIDs: ["com.tinyspeck.slackmacgap"],
        processNames: ["Slack"],
        supportFolder: "Slack"
    )
}
