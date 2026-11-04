import SwiftUI
import StorageCore

/// Stacked bar split into cache / rebuildable / your data by bytes.
/// `scale` is the byte count that fills the full width, so rows in a list compare to each other.
struct RiskBar: View {
    let cache: Int64
    let rebuildable: Int64
    let userData: Int64
    let scale: Int64

    init(footprint: AppFootprint, scale: Int64) {
        self.cache = footprint.bytes(for: .cache)
        self.rebuildable = footprint.bytes(for: .rebuildable)
        self.userData = footprint.bytes(for: .userData)
        self.scale = scale
    }

    init(cache: Int64, rebuildable: Int64, userData: Int64, scale: Int64) {
        self.cache = cache
        self.rebuildable = rebuildable
        self.userData = userData
        self.scale = scale
    }

    var body: some View {
        GeometryReader { geo in
            let full = max(scale, 1)
            HStack(spacing: 1) {
                segment(cache, .green, full, geo.size.width)
                segment(rebuildable, .orange, full, geo.size.width)
                segment(userData, .red, full, geo.size.width)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Cache \(ByteText.string(cache)), rebuildable \(ByteText.string(rebuildable)), your data \(ByteText.string(userData))")
    }

    @ViewBuilder
    private func segment(_ bytes: Int64, _ color: Color, _ full: Int64, _ width: CGFloat) -> some View {
        if bytes > 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: max(2, width * CGFloat(bytes) / CGFloat(full)))
        }
    }
}

#Preview {
    VStack(alignment: .leading) {
        let apps = StorageSnapshot.sample.apps
        ForEach(apps.prefix(4)) { RiskBar(footprint: $0, scale: apps[0].totalBytes) }
    }
    .padding()
    .frame(width: 300)
}
