import StorageCore

extension AppDefinition {
    static let postman = AppDefinition.electron(
        id: "postman",
        displayName: "Postman",
        bundleIDs: ["com.postmanlabs.mac"],
        processNames: ["Postman"],
        supportFolder: "Postman"
    )
}
