import Foundation
import Testing
import StorageCore

@Suite struct ProtectedPathListTests {
    static let home = URL(fileURLWithPath: "/Users/sample")

    @Test func containsExpandedHomeEntriesAndSystem() {
        let entries = ProtectedPathList.entries(home: Self.home)
        #expect(entries.contains("/Users/sample/Library/Keychains"))
        #expect(entries.contains("/System"))
        #expect(!entries.contains { $0.hasPrefix("~") })
    }

    @Test(arguments: [
        ".ssh", ".gnupg", "Library/Calendars", "Library/Application Support/AddressBook", "Library/Safari",
        "Library/Group Containers/group.com.apple.notes", "Library/Containers/com.apple.Notes",
        "Library/Application Support/MobileSync", "Library/Cookies", ".Trash",
    ])
    func personalDataIsProtected(relative: String) {
        let protected = ProtectedPaths(home: Self.home)
        #expect(protected.isProtected("/Users/sample/\(relative)"))
        #expect(protected.isProtected("/Users/sample/\(relative)/inside"))
    }

    @Test func neighboursStayCleanable() {
        // Their caches live elsewhere and stay cleanable.
        let protected = ProtectedPaths(home: Self.home)
        #expect(!protected.isProtected("/Users/sample/Library/Caches/com.apple.Safari"))
        #expect(!protected.isProtected("/Users/sample/Library/Containers/com.example.Notes"))
    }

    // MARK: - overlaps(pattern:)

    @Test func overlapsReturnsTheEntryHit() {
        let protected = ProtectedPaths(home: Self.home)
        let keychains = "/Users/sample/Library/Keychains"
        #expect(protected.overlaps(pattern: "~/Library/Keychains") == keychains)            // equal
        #expect(protected.overlaps(pattern: "~/Library/Keychains/*") == keychains)          // inside
        #expect(protected.overlaps(pattern: "~/Library/*") != nil)                          // ancestor
        #expect(protected.overlaps(pattern: "~/Library/Key*") == keychains)                 // glob over the entry
        #expect(protected.overlaps(pattern: "~/Pictures/Photos Library.photoslibrary/x") == "*.photoslibrary")
        #expect(protected.overlaps(pattern: "/System/Library/Caches") == "/System")
        #expect(protected.overlaps(pattern: "/Volumes/*/Backups.backupdb") == "/Volumes/*/Backups.backupdb")
        #expect(protected.overlaps(pattern: "/Volumes/*") != nil)                           // ancestor of a glob entry
    }

    @Test func overlapsIsNilForCleanableLocations() {
        let protected = ProtectedPaths(home: Self.home)
        for pattern in [
            "~/Library/Caches/com.example.app", "~/Library/Application Support/Example/Cache",
            "~/Library/Mailbox", "/usr/local/lib/example", "/Volumes/Data/Other",
        ] {
            #expect(protected.overlaps(pattern: pattern) == nil, "\(pattern)")
        }
    }
}

@Suite struct InspectorUnavailableTests {
    @Test func labeledInitSetsReason() {
        #expect(InspectorUnavailable(reason: "x").reason == "x")
        #expect(InspectorUnavailable("y").reason == "y")
    }
}
