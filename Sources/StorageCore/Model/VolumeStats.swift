public struct VolumeStats: Sendable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
    public let purgeableBytes: Int64
    public let systemVolumeBytes: Int64
    public let localSnapshotCount: Int

    public init(
        totalBytes: Int64,
        usedBytes: Int64,
        availableBytes: Int64,
        purgeableBytes: Int64,
        systemVolumeBytes: Int64,
        localSnapshotCount: Int
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
        self.systemVolumeBytes = systemVolumeBytes
        self.localSnapshotCount = localSnapshotCount
    }
}
