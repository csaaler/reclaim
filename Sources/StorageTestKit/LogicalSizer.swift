import Foundation
import StorageCore

/// A `SizeMeasuring` that sums logical file sizes without following symlinks.
/// Fixture files are written with real bytes, so this approximates allocated size.
public struct LogicalSizer: SizeMeasuring {
    public init() {}

    public func allocatedSize(of path: String) async -> Int64 {
        size(of: path)
    }

    private func size(of path: String) -> Int64 {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path) else { return 0 }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular?:
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        case .typeDirectory?:
            var total: Int64 = 0
            let url = URL(fileURLWithPath: path)
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        default:
            return 0
        }
    }
}
