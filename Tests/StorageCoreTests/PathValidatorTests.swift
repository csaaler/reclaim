import Testing
import Foundation
@testable import StorageCore

@Suite struct PathValidatorTests {
    let root: String
    let home: URL
    let validator: PathValidator

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = FileSystem.realpath(base.path)!
        home = URL(fileURLWithPath: root + "/Users/sample")
        for dir in ["Library/Keychains", "Library/Caches/com.foo", "Pictures/Photos Library.photoslibrary", "Pictures/Other/Deep"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home.path + "/Library/Keychains/login.keychain-db", contents: Data("k".utf8))
        FileManager.default.createFile(atPath: home.path + "/Pictures/Photos Library.photoslibrary/x", contents: Data("p".utf8))
        validator = PathValidator(home: home, allowedRoots: [home.path])
    }

    private func violation(_ path: String, id: FileID? = nil) -> SafetyViolation? {
        do { _ = try validator.validate(path, expectedFileID: id); return nil } catch { return error }
    }

    @Test func protectedExact() { #expect(violation(home.path + "/Library/Keychains") == .protected(home.path + "/Library/Keychains")) }
    @Test func protectedDescendant() {
        let p = home.path + "/Library/Keychains/login.keychain-db"
        #expect(violation(p) == .protected(p))
    }
    @Test func protectedAncestor() { #expect(violation(home.path + "/Library") == .protected(home.path + "/Library")) }
    @Test func protectedCaseInsensitive() {
        let p = home.path + "/library/KEYCHAINS/x"
        #expect(violation(p) == .protected(p))
    }
    @Test func photosLibraryAnywhere() {
        let p = home.path + "/Pictures/Photos Library.photoslibrary/x"
        #expect(violation(p) == .protected(p))
    }
    @Test func photosLibraryAncestorOnDisk() {
        let p = home.path + "/Pictures"
        #expect(violation(p) == .protected(p))
        // A directory with no library below it is fine.
        #expect(violation(home.path + "/Pictures/Other") == nil)
    }
    @Test func trashAndItsContentsAreProtected() throws {
        let trash = home.path + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash + "/Old Folder", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: trash + "/old.bin", contents: Data("t".utf8))
        for path in [trash, trash + "/old.bin", trash + "/Old Folder", home.path + "/.trash/OLD.bin"] {
            #expect(violation(path) == .protected(path), "\(path)")
        }
    }
    @Test func symlinkEscape() throws {
        let link = home.path + "/Library/Caches/evil"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home.path + "/Library/Keychains")
        let inside = link + "/login.keychain-db"
        #expect(violation(inside) == .protected(inside))
        #expect(violation(link) == nil)
        #expect(try validator.validate(link, expectedFileID: nil) == link)
    }
    @Test func outsideRoots() throws {
        let other = root + "/opt/homebrew"
        try FileManager.default.createDirectory(atPath: other + "/x", withIntermediateDirectories: true)
        #expect(violation(other + "/x") == .outsideAllowedRoots(other + "/x"))
    }
    @Test func usrLocalNotProtectedButOutsideRoots() {
        let protected = ProtectedPaths(home: home)
        #expect(!protected.isProtected("/usr/local/bin/x"))
        #expect(!protected.isProtected("/usr/local"))
        #expect(protected.isProtected("/usr/lib"))
        if FileManager.default.fileExists(atPath: "/usr/local") {
            #expect(violation("/usr/local") == .outsideAllowedRoots("/usr/local"))
        }
    }
    @Test func identityChanged() throws {
        let file = home.path + "/Library/Caches/com.foo/f"
        FileManager.default.createFile(atPath: file, contents: Data("a".utf8))
        let before = FileID.of(path: file)!
        try FileManager.default.moveItem(atPath: file, toPath: file + ".old")
        FileManager.default.createFile(atPath: file, contents: Data("b".utf8))
        #expect(FileID.of(path: file) != before)
        #expect(violation(file, id: before) == .identityChanged(file))
        #expect(violation(file, id: FileID.of(path: file)) == nil)
    }
    @Test func notFound() { #expect(violation(home.path + "/Library/Caches/nope") == .notFound(home.path + "/Library/Caches/nope")) }
    @Test func notAbsolute() { #expect(violation("Library/Caches") == .notAbsolute("Library/Caches")) }
    @Test func dotDotRejected() {
        let p = home.path + "/Library/Caches/../Keychains"
        #expect(violation(p) == .notStandardized(p))
        #expect(violation(home.path + "/Library/Caches/./com.foo") == .notStandardized(home.path + "/Library/Caches/./com.foo"))
    }
    @Test func nulRejected() {
        for p in [home.path + "/Library/Keychains\0", home.path + "/Library/Caches/com.foo\0"] {
            #expect(violation(p) == .notStandardized(p))
        }
    }
    @Test func unreadableSubdirectoryFailsClosed() throws {
        let locked = home.path + "/Stuff/locked"
        try FileManager.default.createDirectory(atPath: locked + "/My.photoslibrary", withIntermediateDirectories: true)
        chmod(locked, 0o000)
        defer { chmod(locked, 0o755) }
        #expect(violation(home.path + "/Stuff") == .protected(home.path + "/Stuff"))
    }
    @Test func allowedRootNotDeletable() throws {
        let sub = home.path + "/Work"
        try FileManager.default.createDirectory(atPath: sub + "/a", withIntermediateDirectories: true)
        let v = PathValidator(home: home, allowedRoots: [sub])
        #expect(throws: SafetyViolation.protected(sub)) { try v.validate(sub, expectedFileID: nil) }
        #expect((try? v.validate(sub + "/a", expectedFileID: nil)) == sub + "/a")
    }
    @Test func prefixCollisionIsNotProtected() throws {
        try FileManager.default.createDirectory(atPath: home.path + "/Library/Mailbox", withIntermediateDirectories: true)
        #expect(violation(home.path + "/Library/Mailbox") == nil)
    }
    @Test func nfdPathIsProtected() {
        // The same home folder name, precomposed (NFC) and decomposed (NFD).
        let nfcHome = URL(fileURLWithPath: "/Users/sample/Caf\u{e9}")
        let nfdPath = "/Users/sample/Cafe\u{301}/Library/Keychains/x"
        #expect(ProtectedPaths(home: nfcHome).isProtected(nfdPath))
    }
    @Test func dataVolumePrefixCaseInsensitive() {
        #expect(ProtectedPaths(home: home).isProtected("/system/volumes/DATA/System/Library"))
        #expect(!ProtectedPaths(home: home).isProtected("/system/volumes/data/Users/sample/Documents"))
    }
    @Test func structuralFolder() {
        #expect(violation(home.path + "/Library/Caches") == .protected(home.path + "/Library/Caches"))
        #expect(violation(home.path) == .protected(home.path))
        #expect(violation(home.path + "/Library/Caches/com.foo") == nil)
    }
    @Test func dataVolumePrefixIsStripped() {
        let protected = ProtectedPaths(home: home)
        #expect(!protected.isProtected("/System/Volumes/Data/Users/sample/Documents"))
        #expect(protected.isProtected("/System/Volumes/Data/System/Library"))
        #expect(protected.isProtected("/System/Volumes/Data" + home.path + "/Library/Keychains/x"))
    }
    @Test func timeMachineEntries() {
        let protected = ProtectedPaths(home: home)
        #expect(protected.isProtected("/Volumes/Backup/Backups.backupdb/Mac/x"))
        #expect(protected.isProtected("/Volumes/Backup/foo.sparsebundle"))
        #expect(protected.isProtected("/Volumes/Backup"))
        #expect(!protected.isProtected("/Volumes/Backup/Other/file"))
    }
}
