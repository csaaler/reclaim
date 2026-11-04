import Foundation
import Testing
import StorageCore
import StorageTestKit

@Suite struct VolumeBoundaryTests {
    /// An in-memory tree: path -> (device, child names or nil for a non-directory).
    struct Tree {
        var nodes: [String: (device: UInt64, children: [String]?)]

        func entry(_ path: String) -> VolumeBoundary.Entry? {
            nodes[path].map { VolumeBoundary.Entry(device: $0.device, isDirectory: $0.children != nil) }
        }

        func children(_ path: String) -> [String]? { nodes[path]?.children }

        func check(_ root: String, maxEntries: Int = 100) -> VolumeBoundary.Finding {
            VolumeBoundary.check(root, maxEntries: maxEntries, lstat: entry, children: children)
        }
    }

    @Test func sameDeviceThroughoutIsSafe() {
        let tree = Tree(nodes: [
            "/c": (1, ["a", "f"]),
            "/c/a": (1, ["b"]),
            "/c/a/b": (1, []),
            "/c/f": (1, nil),
        ])
        #expect(tree.check("/c") == .sameVolume)
    }

    @Test func nestedMountIsFound() {
        let tree = Tree(nodes: [
            "/c": (1, ["a"]),
            "/c/a": (1, ["mnt"]),
            "/c/a/mnt": (7, ["data"]),
            "/c/a/mnt/data": (7, nil),
        ])
        #expect(tree.check("/c") == .otherVolume("/c/a/mnt"))
    }

    @Test func fileOnAnotherDeviceIsFound() {
        let tree = Tree(nodes: ["/c": (1, ["f"]), "/c/f": (2, nil)])
        #expect(tree.check("/c") == .otherVolume("/c/f"))
    }

    @Test func walkIsBounded() {
        var nodes: [String: (device: UInt64, children: [String]?)] = ["/c": (1, (0..<50).map { "f\($0)" })]
        for i in 0..<50 { nodes["/c/f\(i)"] = (1, nil) }
        #expect(Tree(nodes: nodes).check("/c", maxEntries: 10) == .tooLarge)
        #expect(Tree(nodes: nodes).check("/c", maxEntries: 100) == .sameVolume)
    }

    @Test func vanishedEntriesAreIgnored() {
        let tree = Tree(nodes: ["/c": (1, ["gone", "f"]), "/c/f": (1, nil)])
        #expect(tree.check("/c") == .sameVolume)
    }

    @Test func realTreeOnOneVolumeIsSafeAndSymlinksAreNotFollowed() throws {
        let fixture = try FixtureHome()
        try fixture.file("c/a/b/file", bytes: 10)
        // A symlink to a directory on another volume is never followed.
        try fixture.symlink("c/a/root", to: "/")
        #expect(VolumeBoundary.check(fixture.home.path + "/c") == .sameVolume)
    }

    @Test func removeRefusesWhenTheCheckFindsAnotherVolume() throws {
        let fixture = try FixtureHome()
        try fixture.file("c/a/file", bytes: 10)
        let path = fixture.home.path + "/c"
        let ops = RealFileOperations(volumeCheck: { _ in .otherVolume(path + "/a") })
        #expect(throws: RealFileOperations.ContainsOtherVolume.self) { try ops.remove(path) }
        #expect(FileManager.default.fileExists(atPath: path + "/a/file"))
        let tooLarge = RealFileOperations(volumeCheck: { _ in .tooLarge })
        #expect(throws: RealFileOperations.TooLargeToCheck.self) { try tooLarge.remove(path) }
        #expect(FileManager.default.fileExists(atPath: path + "/a/file"))
        #expect(RealFileOperations.ContainsOtherVolume(path: path).localizedDescription == "Contains another volume")
    }
}
