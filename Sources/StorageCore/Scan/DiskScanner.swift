import Darwin
import Foundation
import Synchronization

public enum DiskScanError: Error, Sendable, Equatable {
    /// The root does not exist or is not a directory.
    case cannotOpenRoot(path: String, errno: Int32)
}

/// Walks a directory tree on one volume and aggregates allocated sizes per directory.
///
/// Allocated (not logical) sizes are summed, hard links are counted once, symlinks are never
/// followed, and other volumes mounted inside the tree are skipped. Only directory aggregates and
/// files at or above `largeFileThreshold` are kept, so memory grows with the number of
/// directories, not the number of files.
public struct DiskScanner: Sendable {
    public let root: String
    public let displayPrefixToStrip: String?
    public let largeFileThreshold: Int64
    public let maxConcurrency: Int
    /// Records folders that macOS guards with a privacy prompt as unreadable without opening
    /// them: each app's folder in `Library/Containers` and `Library/Group Containers`, the Music,
    /// TV and Photos libraries, and `/Volumes`. Without Full Disk Access, opening one waits on a
    /// prompt ("data from other apps", "your media library", …) that may never be answered.
    public private(set) var skipsPrivacyPromptedFolders: Bool

    public init(
        root: String,
        displayPrefixToStrip: String? = nil,
        largeFileThreshold: Int64 = 100 * 1_048_576,
        maxConcurrency: Int = 8,
        skipsPrivacyPromptedFolders: Bool = false
    ) {
        self.root = Self.trimmingTrailingSlash(root)
        self.displayPrefixToStrip = displayPrefixToStrip.map(Self.trimmingTrailingSlash)
        self.largeFileThreshold = largeFileThreshold
        self.maxConcurrency = max(1, maxConcurrency)
        self.skipsPrivacyPromptedFolders = skipsPrivacyPromptedFolders
    }

    /// The Data volume. Display paths are stripped to `/Users/...`, `/Library/...` and so on,
    /// matching the firmlinks the user sees.
    public static let dataVolume = DiskScanner(root: "/System/Volumes/Data", displayPrefixToStrip: "/System/Volumes/Data")

    /// A copy that skips privacy-prompted folders; see `skipsPrivacyPromptedFolders`.
    public func skippingPrivacyPromptedFolders() -> DiskScanner {
        var copy = self
        copy.skipsPrivacyPromptedFolders = true
        return copy
    }

    /// Progress is reported at most about 4 times per second, plus once when the scan completes.
    /// The callback may run on any thread.
    public func scan(progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        var info = stat()
        guard stat(root, &info) == 0 else {
            throw DiskScanError.cannotOpenRoot(path: root, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw DiskScanError.cannotOpenRoot(path: root, errno: ENOTDIR)
        }

        let state = ScanState(
            rootDevice: info.st_dev,
            threshold: largeFileThreshold,
            prefix: displayPrefixToStrip,
            skipsPrivacyPromptedFolders: skipsPrivacyPromptedFolders,
            extraWorkers: maxConcurrency - 1,
            progress: progress
        )
        let summary = await state.scanDirectory(realPath: root, depth: 0)
            ?? DirectorySummary(
                path: state.display(root), allocatedBytes: 0, fileCount: 0,
                newestModification: nil, isUnreadable: false, children: []
            )
        try Task.checkCancellation()
        state.emit(currentPath: summary.path)
        return state.result(root: summary)
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// A `SizeMeasuring` backed by `DiskScanner`: allocated bytes of a directory tree, or of a single
/// non-directory item (a symlink is measured itself, never its target). Returns 0 for missing paths.
public struct ScannerSizer: SizeMeasuring {
    public init() {}

    public func allocatedSize(of path: String) async -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }
        let result = try? await DiskScanner(root: path, largeFileThreshold: .max).scan { _ in }
        return result?.root.allocatedBytes ?? 0
    }
}

/// State shared by all scanning tasks of one scan.
private final class ScanState: Sendable {
    let rootDevice: Int32
    let threshold: Int64
    let prefix: String?
    let skipsPrivacyPromptedFolders: Bool
    let progress: @Sendable (ScanProgress) -> Void

    private let seenLinked = Mutex<Set<FileID>>([])
    private let largeFiles = Mutex<[LargeFile]>([])
    private let unreadable = Mutex<[String]>([])
    private let completedTopLevel = Mutex<[DirectorySummary]>([])
    private let lastEmit = Mutex<ContinuousClock.Instant?>(nil)
    private let bytesSoFar = Atomic<Int64>(0)
    private let filesSoFar = Atomic<Int>(0)
    /// Permits for additional concurrent tasks beyond the caller's.
    private let freeWorkers: Atomic<Int>

    private static let emitInterval = Duration.milliseconds(250)

    init(
        rootDevice: Int32,
        threshold: Int64,
        prefix: String?,
        skipsPrivacyPromptedFolders: Bool,
        extraWorkers: Int,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) {
        self.rootDevice = rootDevice
        self.threshold = threshold
        self.prefix = prefix
        self.skipsPrivacyPromptedFolders = skipsPrivacyPromptedFolders
        self.progress = progress
        self.freeWorkers = Atomic(max(0, extraWorkers))
    }

    func display(_ realPath: String) -> String {
        guard let prefix, realPath.hasPrefix(prefix) else { return realPath }
        let rest = realPath.dropFirst(prefix.count)
        if rest.isEmpty { return "/" }
        return rest.first == "/" ? String(rest) : realPath
    }

    /// Nil when the directory vanished, was replaced by a non-directory, or is on another volume.
    func scanDirectory(realPath: String, depth: Int) async -> DirectorySummary? {
        let displayPath = display(realPath)
        if Task.isCancelled { return nil }
        if skipsPrivacyPromptedFolders && depth > 0 && Self.isPrivacyPrompted(realPath, depth: depth) {
            return unreadableSummary(displayPath)
        }

        // The root may be given through a symlink (e.g. /tmp); nothing below it is followed.
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (depth == 0 ? 0 : O_NOFOLLOW)
        let fd = open(realPath, flags)
        if fd < 0 {
            let code = errno
            if depth > 0 && (code == ENOENT || code == ENOTDIR || code == ELOOP) { return nil }
            // EACCES/EPERM (no permission or no Full Disk Access) and anything else unexpected.
            return unreadableSummary(displayPath)
        }
        var info = stat()
        if fstat(fd, &info) == 0 && info.st_dev != rootDevice {
            close(fd)
            return nil
        }
        let (entries, errorCode) = BulkAttributes.entries(of: fd)
        close(fd)
        let isUnreadable = errorCode != nil
        if isUnreadable { unreadable.withLock { $0.append(displayPath) } }

        var bytes: Int64 = 0
        var fileCount = 0
        var newest: Double?
        var subdirectories: [String] = []
        var large: [LargeFile] = []
        for entry in entries where entry.device == rootDevice {
            if entry.kind == .directory {
                subdirectories.append(Self.child(of: realPath, named: entry.name))
                continue
            }
            if entry.linkCount > 1 && !firstSighting(FileID(device: entry.device, inode: entry.inode)) {
                continue
            }
            bytes += entry.allocatedSize
            fileCount += 1
            newest = max(newest ?? entry.modified, entry.modified)
            if entry.kind == .regular && entry.allocatedSize >= threshold {
                large.append(LargeFile(
                    path: display(Self.child(of: realPath, named: entry.name)),
                    allocatedBytes: entry.allocatedSize,
                    modified: Date(timeIntervalSince1970: entry.modified)
                ))
            }
        }
        if !large.isEmpty { largeFiles.withLock { $0.append(contentsOf: large) } }
        bytesSoFar.add(bytes, ordering: .relaxed)
        filesSoFar.add(fileCount, ordering: .relaxed)

        var children = await scanChildren(subdirectories, depth: depth + 1)
        var newestDate = newest.map { Date(timeIntervalSince1970: $0) }
        for child in children {
            bytes += child.allocatedBytes
            fileCount += child.fileCount
            if let childNewest = child.newestModification {
                newestDate = max(newestDate ?? childNewest, childNewest)
            }
        }
        children.sort(by: Self.largestFirst)

        let summary = DirectorySummary(
            path: displayPath, allocatedBytes: bytes, fileCount: fileCount,
            newestModification: newestDate, isUnreadable: isUnreadable, children: children
        )
        if depth == 1 { completedTopLevel.withLock { $0.append(summary) } }
        emitIfDue(currentPath: displayPath)
        return summary
    }

    private func unreadableSummary(_ displayPath: String) -> DirectorySummary {
        unreadable.withLock { $0.append(displayPath) }
        return DirectorySummary(
            path: displayPath, allocatedBytes: 0, fileCount: 0,
            newestModification: nil, isUnreadable: true, children: []
        )
    }

    private static func isPrivacyPrompted(_ path: String, depth: Int) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = parts.last else { return false }
        if depth == 1 && name == "Volumes" { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.hasSuffix("/Library/Containers") || parent.hasSuffix("/Library/Group Containers") { return true }
        // Libraries directly inside a user's home: /Users/<name>/<Music|Movies|Pictures>/<library>.
        guard parts.count >= 4, parts[parts.count - 4] == "Users" else { return false }
        switch parts[parts.count - 2] {
        case "Music": return name == "Music" || name == "iTunes"
        case "Movies": return name == "TV"
        case "Pictures": return name.hasSuffix(".photoslibrary")
        default: return false
        }
    }

    /// Scans `paths`, handing each to a new task while permits are free and scanning it inline
    /// otherwise. This keeps at most `maxConcurrency` tasks doing I/O at once.
    private func scanChildren(_ paths: [String], depth: Int) async -> [DirectorySummary] {
        if paths.isEmpty { return [] }
        return await withTaskGroup(of: DirectorySummary?.self) { group in
            var results: [DirectorySummary] = []
            results.reserveCapacity(paths.count)
            for path in paths {
                if tryAcquireWorker() {
                    group.addTask {
                        defer { self.releaseWorker() }
                        return await self.scanDirectory(realPath: path, depth: depth)
                    }
                } else if let summary = await scanDirectory(realPath: path, depth: depth) {
                    results.append(summary)
                }
            }
            for await summary in group {
                if let summary { results.append(summary) }
            }
            return results
        }
    }

    private func tryAcquireWorker() -> Bool {
        var current = freeWorkers.load(ordering: .relaxed)
        while current > 0 {
            let (exchanged, original) = freeWorkers.compareExchange(
                expected: current, desired: current - 1, ordering: .acquiringAndReleasing
            )
            if exchanged { return true }
            current = original
        }
        return false
    }

    private func releaseWorker() {
        freeWorkers.add(1, ordering: .acquiringAndReleasing)
    }

    private func firstSighting(_ id: FileID) -> Bool {
        seenLinked.withLock { $0.insert(id).inserted }
    }

    private func emitIfDue(currentPath: String) {
        let now = ContinuousClock.now
        let due = lastEmit.withLock { last -> Bool in
            if let last, now - last < Self.emitInterval { return false }
            last = now
            return true
        }
        if due { emit(currentPath: currentPath) }
    }

    func emit(currentPath: String) {
        let topLevel = completedTopLevel.withLock { $0 }.sorted(by: Self.largestFirst)
        progress(ScanProgress(
            currentPath: currentPath,
            bytesSoFar: bytesSoFar.load(ordering: .relaxed),
            filesSoFar: filesSoFar.load(ordering: .relaxed),
            completedTopLevel: topLevel
        ))
    }

    func result(root: DirectorySummary) -> ScanResult {
        let large = largeFiles.withLock { $0 }.sorted {
            $0.allocatedBytes != $1.allocatedBytes ? $0.allocatedBytes > $1.allocatedBytes : $0.path < $1.path
        }
        return ScanResult(root: root, largeFiles: large, unreadablePaths: unreadable.withLock { $0 }.sorted())
    }

    private static func largestFirst(_ a: DirectorySummary, _ b: DirectorySummary) -> Bool {
        a.allocatedBytes != b.allocatedBytes ? a.allocatedBytes > b.allocatedBytes : a.path < b.path
    }

    private static func child(of parent: String, named name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }
}
