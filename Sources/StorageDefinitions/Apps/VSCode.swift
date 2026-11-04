import StorageCore

extension AppDefinition {
    static let vscode = AppDefinition.electron(
        id: "vscode",
        displayName: "Visual Studio Code",
        bundleIDs: ["com.microsoft.VSCode"],
        processNames: ["Code"],
        supportFolder: "Code"
    )
}
