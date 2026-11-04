import Darwin
import Foundation
import Synchronization
import Testing
import StorageCore
import StorageTestKit

private let mib: Int64 = 1_048_576

/// Allocated bytes of one file, via `lstat` (`st_blocks` is in 512-byte units).
private func allocated(_ path: String) -> Int64 {
    var info = stat()
    guard lstat(path, &info) == 0 else { return -1 }
    return Int64(info.st_blocks) * 512
}

private func scan(
    _ root: String,
    strip: String? = nil,
    threshold: Int64 = 100 * 1_048_576
) async throws -> ScanResult {
    try await DiskScanner(root: root, displayPrefixToStrip: strip, largeFileThreshold: threshold)
        .scan { _ in }
}

@Suite struct DiskScannerTests {
    @Test func allocatedSizeNotLogical() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.dir("sparse")
        let sparsePath = root + "/sparse/ten-mb"
        let fd = open(sparsePath, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(10 * mib)) == 0)
        close(fd)
        try fixture.file("dense/one-mb", bytes: Int(mib))

        let result = try await scan(root)

        let sparse = try #require(result.summary(at: root + "/sparse"))
        let dense = try #require(result.summary(at: root + "/dense"))
        #expect(sparse.allocatedBytes < mib)
        #expect(dense.allocatedBytes >= mib)
        #expect(sparse.fileCount == 1)
    }

    @Test func hardLinksCountedOnce() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.file("a/original", bytes: Int(mib))
        try fixture.dir("b")
        try FileManager.default.linkItem(atPath: root + "/a/original", toPath: root + "/b/link")

        let result = try await scan(root)

        #expect(result.root.allocatedBytes >= mib)
        #expect(result.root.allocatedBytes < mib + mib / 2)
        #expect(result.root.fileCount == 1)
    }

    @Test func symlinksNotFollowed() async throws {
        let fixture = try FixtureHome()
        let outside = try FixtureHome()
        try outside.file("big/five-mb", bytes: Int(5 * mib))
        try fixture.symlink("inside/link", to: outside.home.path + "/big")
        try fixture.file("inside/small", bytes: 4096)

        let result = try await scan(fixture.home.path)

        #expect(result.root.allocatedBytes < 100 * 1024)
        #expect(result.root.children.map(\.path) == [fixture.home.path + "/inside"])
        withExtendedLifetime(outside) {}
    }

    @Test func unreadableDirRecorded() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.file("locked/secret", bytes: 8192)
        try fixture.file("open/visible", bytes: 8192)
        let locked = root + "/locked"
        #expect(chmod(locked, 0) == 0)
        defer { chmod(locked, 0o755); withExtendedLifetime(fixture) {} }

        let result = try await scan(root)

        #expect(result.unreadablePaths == [locked])
        let lockedSummary = try #require(result.summary(at: locked))
        #expect(lockedSummary.isUnreadable)
        #expect(lockedSummary.allocatedBytes == 0)
        let openSummary = try #require(result.summary(at: root + "/open"))
        #expect(!openSummary.isUnreadable)
        #expect(openSummary.fileCount == 1)
        #expect(!result.root.isUnreadable)
    }

    /// Without Full Disk Access, opening these folders waits on a privacy prompt (app data, media
    /// library, Photos, TV, network and removable volumes), so each is recorded as unreadable
    /// without being opened.
    @Test func privacyPromptedFoldersSkippedWhenRequested() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        let user = "Users/me"
        try fixture.file("\(user)/Library/Containers/com.example.app/Data/blob", bytes: 8192)
        try fixture.file("\(user)/Library/Group Containers/group.com.example/blob", bytes: 8192)
        try fixture.file("\(user)/Library/Containers/.loose-file", bytes: 4096)
        try fixture.file("\(user)/Music/Music/Media.localized/song", bytes: 8192)
        try fixture.file("\(user)/Pictures/Photos Library.photoslibrary/database/db", bytes: 8192)
        try fixture.file("\(user)/Movies/TV/Media.localized/show", bytes: 8192)
        try fixture.file("Volumes/Share/file", bytes: 8192)
        try fixture.file("\(user)/Music/Logic/project", bytes: 8192)
        try fixture.file("\(user)/Pictures/holiday.jpg", bytes: 8192)
        try fixture.file("\(user)/Library/Caches/kept", bytes: 8192)

        let result = try await DiskScanner(root: root, skipsPrivacyPromptedFolders: true).scan { _ in }

        let skipped = [
            "\(user)/Library/Containers/com.example.app", "\(user)/Library/Group Containers/group.com.example",
            "\(user)/Music/Music", "\(user)/Pictures/Photos Library.photoslibrary", "\(user)/Movies/TV", "Volumes",
        ].map { root + "/" + $0 }
        #expect(result.unreadablePaths.sorted() == skipped.sorted())
        for path in skipped {
            let summary = try #require(result.summary(at: path))
            #expect(summary.isUnreadable)
            #expect(summary.allocatedBytes == 0)
            #expect(summary.children.isEmpty)
        }
        #expect(result.summary(at: root + "/\(user)/Library/Containers")?.fileCount == 1)
        #expect(result.summary(at: root + "/\(user)/Music/Logic")?.fileCount == 1)
        #expect(result.summary(at: root + "/\(user)/Pictures")?.fileCount == 1)
        #expect(result.summary(at: root + "/\(user)/Library/Caches")?.fileCount == 1)

        let full = try await scan(root)
        #expect(full.unreadablePaths.isEmpty)
        #expect(full.summary(at: skipped[0])?.fileCount == 1)
    }

    @Test func childrenSortedAndAggregated() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let middle = Date(timeIntervalSince1970: 1_650_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.file("parent/top.bin", bytes: 50_000, modified: old)
        try fixture.file("parent/small/s.bin", bytes: 10_000, modified: old)
        try fixture.file("parent/big/b1.bin", bytes: 300_000, modified: middle)
        try fixture.file("parent/big/deep/b2.bin", bytes: 200_000, modified: newest)
        try fixture.file("parent/medium/m.bin", bytes: 100_000, modified: old)

        let result = try await scan(root)

        let parent = try #require(result.summary(at: root + "/parent"))
        let childSum = parent.children.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(parent.allocatedBytes == allocated(root + "/parent/top.bin") + childSum)
        #expect(parent.children.map(\.path) == [
            root + "/parent/big", root + "/parent/medium", root + "/parent/small",
        ])
        let big = try #require(result.summary(at: root + "/parent/big"))
        #expect(big.allocatedBytes == allocated(root + "/parent/big/b1.bin") + allocated(root + "/parent/big/deep/b2.bin"))
        #expect(big.fileCount == 2)
        #expect(parent.fileCount == 5)
        #expect(parent.newestModification == newest)
        #expect(result.summary(at: root + "/parent/small")?.newestModification == old)
        #expect(result.root.allocatedBytes == parent.allocatedBytes)
    }

    @Test func largeFilesCollected() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.file("media/two-mb", bytes: Int(2 * mib))
        try fixture.file("media/half-mb", bytes: Int(mib / 2))
        try fixture.file("other/three-mb", bytes: Int(3 * mib))

        let result = try await scan(root, threshold: mib)

        #expect(result.largeFiles.map(\.path) == [root + "/other/three-mb", root + "/media/two-mb"])
        #expect(result.largeFiles.allSatisfy { $0.allocatedBytes >= mib })
    }

    @Test func displayPrefixStripped() async throws {
        let fixture = try FixtureHome()
        let data = fixture.home.path + "/x/Data"
        try fixture.file("x/Data/sub/inner/file", bytes: Int(2 * mib))

        let result = try await scan(data, strip: data, threshold: mib)

        #expect(result.root.path == "/")
        #expect(result.root.children.map(\.path) == ["/sub"])
        #expect(result.summary(at: "/sub/inner")?.fileCount == 1)
        #expect(result.largeFiles.map(\.path) == ["/sub/inner/file"])
    }

    @Test func progressReportsTopLevel() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.file("alpha/a", bytes: 4096)
        try fixture.file("beta/nested/b", bytes: 4096)
        try fixture.file("loose", bytes: 4096)
        let events = Mutex<[ScanProgress]>([])

        let result = try await DiskScanner(root: root).scan { progress in
            events.withLock { $0.append(progress) }
        }

        let collected = events.withLock { $0 }
        let seen = Set(collected.flatMap { $0.completedTopLevel.map(\.path) })
        #expect(seen == [root + "/alpha", root + "/beta"])
        let last = try #require(collected.last)
        #expect(Set(last.completedTopLevel.map(\.path)) == [root + "/alpha", root + "/beta"])
        #expect(last.filesSoFar == 3)
        #expect(last.bytesSoFar == result.root.allocatedBytes)
    }

    @Test func progressIsThrottled() async throws {
        let fixture = try FixtureHome()
        for index in 0..<400 {
            try fixture.file("d\(index % 20)/e\(index)/f", bytes: 10)
        }
        let count = Mutex(0)
        let clock = ContinuousClock()
        let start = clock.now

        _ = try await DiskScanner(root: fixture.home.path).scan { _ in
            count.withLock { $0 += 1 }
        }

        let elapsed = clock.now - start
        let allowed = Int(elapsed / .milliseconds(250)) + 2
        #expect(count.withLock { $0 } <= allowed)
        #expect(count.withLock { $0 } >= 1)
    }

    @Test func scannerSizerMeasuresDirectoriesAndFiles() async throws {
        let fixture = try FixtureHome()
        let root = fixture.home.path
        try fixture.file("d/one", bytes: Int(mib))
        try fixture.file("d/sub/two", bytes: Int(mib))

        let sizer = ScannerSizer()
        let dirSize = await sizer.allocatedSize(of: root + "/d")
        let fileSize = await sizer.allocatedSize(of: root + "/d/one")
        let missing = await sizer.allocatedSize(of: root + "/nope")

        #expect(dirSize == allocated(root + "/d/one") + allocated(root + "/d/sub/two"))
        #expect(fileSize == allocated(root + "/d/one"))
        #expect(missing == 0)
    }

    @Test func missingRootThrows() async throws {
        let fixture = try FixtureHome()
        await #expect(throws: DiskScanError.self) {
            _ = try await scan(fixture.home.path + "/does-not-exist")
        }
    }

    @Test func dataVolumeConfiguration() {
        let scanner = DiskScanner.dataVolume
        #expect(scanner.root == "/System/Volumes/Data")
        #expect(scanner.displayPrefixToStrip == "/System/Volumes/Data")
        #expect(!scanner.skipsPrivacyPromptedFolders)
    }

    @Test func skippingCopyKeepsOtherSettings() {
        let scanner = DiskScanner(root: "/tmp/x", displayPrefixToStrip: "/tmp", largeFileThreshold: 42, maxConcurrency: 3)
        let copy = scanner.skippingPrivacyPromptedFolders()
        #expect(copy.skipsPrivacyPromptedFolders)
        #expect(copy.root == scanner.root)
        #expect(copy.displayPrefixToStrip == scanner.displayPrefixToStrip)
        #expect(copy.largeFileThreshold == scanner.largeFileThreshold)
        #expect(copy.maxConcurrency == scanner.maxConcurrency)
    }
}
