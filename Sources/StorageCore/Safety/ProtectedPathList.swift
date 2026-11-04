import Foundation

/// The hard-blocked locations. No cleanup action may touch them, and no definition may name them.
///
/// `entries(home:)` returns three kinds of entry. A path `P` (a display path, i.e. with any
/// `/System/Volumes/Data` prefix already stripped) is protected by an entry `E` when:
///
/// 1. **Literal absolute path** (no `*`, e.g. `/System`, `<home>/Library/Keychains`):
///    `P` is the same as `E` (exact), `P` is inside `E` (descendant), or `E` is inside `P`
///    (ancestor: deleting `P` would delete `E`). Compare with `PathKey`.
/// 2. **Absolute pattern** (starts with `/`, contains `*`, e.g. `/Volumes/*/Backups.backupdb`):
///    exact/descendant when `PathPattern.matches(E, path:)` holds for `P` or any ancestor of `P`;
///    ancestor when `P` matches the leading segments of `E` (e.g. `/Volumes/Backup Disk`).
/// 3. **Anywhere pattern** (no leading `/`, e.g. `*.photoslibrary`): a suffix pattern.
///    Exact/descendant when `PathPattern.matches(E, path:)` holds for `P` or any ancestor of `P`
///    (i.e. some segment of `P` is a photos library). Whether `P` *contains* a match cannot be
///    decided from the path alone; a validator that needs the ancestor rule must look on disk.
///
/// `exceptions` lists paths carved out of an entry: `/usr/local` and its descendants are not
/// protected by the `/usr` entry.
public enum ProtectedPathList {
    /// Paths exempt from the entry that contains them (exact or descendant).
    public static let exceptions = ["/usr/local"]

    public static func entries(home: URL) -> [String] {
        let library = home.path + "/Library"
        return [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            // Keys and credentials
            home.path + "/.ssh",
            home.path + "/.gnupg",
            library + "/Keychains",
            library + "/Accounts",
            library + "/Cookies",
            // Synced and cloud files
            library + "/Mobile Documents",
            library + "/CloudStorage",
            // Personal data of Apple apps
            library + "/Mail",
            library + "/Messages",
            library + "/Calendars",
            library + "/Application Support/AddressBook",
            library + "/Safari",
            library + "/Group Containers/group.com.apple.notes",
            library + "/Containers/com.apple.Notes",
            library + "/Preferences",
            // iPhone and iPad backups
            library + "/Application Support/MobileSync",
            "*.photoslibrary",
            // Files the user moved to the Trash; only Finder empties it
            home.path + "/.Trash",
            // Time Machine data
            "/Volumes/*/Backups.backupdb",
            "/Volumes/*/*.backupbundle",
            "/Volumes/*/*.sparsebundle",
        ]
    }
}
