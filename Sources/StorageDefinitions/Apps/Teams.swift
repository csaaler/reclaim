import StorageCore

extension AppDefinition {
    // New Teams is a WebView2 app inside its sandbox container, so its Chromium caches live under
    // the container's EBWebView profile. The classic Application Support path is kept for older installs.
    private static let teamsWebView =
        "~/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/EBWebView"

    static let teams = AppDefinition.electron(
        id: "teams",
        displayName: "Microsoft Teams",
        bundleIDs: ["com.microsoft.teams2"],
        processNames: ["MSTeams"],
        supportFolder: "Microsoft/MSTeams",
        extraLocations: ["Default/Cache", "Default/Code Cache", "Default/GPUCache", "GraphiteDawnCache",
                         "GrShaderCache", "ShaderCache", "GPUPersistentCache"].map {
            DefinedLocation(
                pattern: "\(teamsWebView)/\($0)",
                kind: .cache,
                note: "Chromium cache; rebuilt automatically"
            )
        }
    )
}
