import Foundation

/// Sizes paths from a finished scan instead of walking the disk again. Paths that are not a
/// directory in the scan tree (files, other volumes, paths outside the scan) go to `fallback`.
public struct ScanTreeSizer: SizeMeasuring {
    public let scan: ScanResult
    public let fallback: any SizeMeasuring

    public init(scan: ScanResult, fallback: any SizeMeasuring = ScannerSizer()) {
        self.scan = scan
        self.fallback = fallback
    }

    public func allocatedSize(of path: String) async -> Int64 {
        if let summary = scan.summary(at: PathKey(path).raw) { return summary.allocatedBytes }
        return await fallback.allocatedSize(of: path)
    }
}
