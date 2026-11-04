import Foundation

public struct DirectorySummary: Sendable, Identifiable {
    public var id: String { path }
    /// Display path, absolute, e.g. "/Users/x/Library".
    public let path: String
    /// Includes all descendants.
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var newestModification: Date?
    public var isUnreadable: Bool
    /// Directories only, sorted by `allocatedBytes` descending.
    public var children: [DirectorySummary]

    public init(
        path: String,
        allocatedBytes: Int64,
        fileCount: Int,
        newestModification: Date?,
        isUnreadable: Bool,
        children: [DirectorySummary]
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.newestModification = newestModification
        self.isUnreadable = isUnreadable
        self.children = children
    }
}

public struct LargeFile: Sendable, Identifiable {
    public let path: String
    public let allocatedBytes: Int64
    public let modified: Date
    public var id: String { path }

    public init(path: String, allocatedBytes: Int64, modified: Date) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.modified = modified
    }
}

public struct ScanResult: Sendable {
    public var root: DirectorySummary
    /// Sorted by size descending.
    public var largeFiles: [LargeFile]
    public var unreadablePaths: [String]

    public init(root: DirectorySummary, largeFiles: [LargeFile], unreadablePaths: [String]) {
        self.root = root
        self.largeFiles = largeFiles
        self.unreadablePaths = unreadablePaths
    }

    /// The summary for the directory at `path`, found by walking children whose path is a prefix of it.
    public func summary(at path: String) -> DirectorySummary? {
        let target = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        var current = root
        while true {
            if current.path == target { return current }
            let next = current.children.first { child in
                target == child.path || target.hasPrefix(child.path + "/")
            }
            guard let next else { return nil }
            current = next
        }
    }
}

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let bytesSoFar: Int64
    public let filesSoFar: Int
    public let completedTopLevel: [DirectorySummary]

    public init(currentPath: String, bytesSoFar: Int64, filesSoFar: Int, completedTopLevel: [DirectorySummary]) {
        self.currentPath = currentPath
        self.bytesSoFar = bytesSoFar
        self.filesSoFar = filesSoFar
        self.completedTopLevel = completedTopLevel
    }
}
