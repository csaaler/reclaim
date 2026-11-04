import StorageCore

extension AppDefinition {
    // vm_bundles is `userData`, not `rebuildable`, because it is not purely a download.
    // `claudevm.bundle` holds vmlinuz, initrd and rootfs.img (each with a `.origin` marker), but
    // also sessiondata.img (no marker, may hold session state), a writable rootfs disk, and
    // per-install machineIdentifier/macAddress. Claude re-downloads the image if it is removed, but
    // the session data would be lost, so removal goes to the Trash.
    static let claude = AppDefinition.electron(
        id: "claude",
        displayName: "Claude",
        bundleIDs: ["com.anthropic.claudefordesktop"],
        processNames: ["Claude"],
        supportFolder: "Claude",
        extraLocations: [
            DefinedLocation(
                pattern: "~/Library/Application Support/Claude/vm_bundles",
                kind: .userData,
                note: "Claude's sandbox VM: downloaded image plus per-install session data; Claude re-downloads the image if removed"
            ),
        ]
    )
}
