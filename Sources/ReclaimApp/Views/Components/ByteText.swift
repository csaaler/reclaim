import SwiftUI

/// A byte count in Finder-style decimal units ("409 GB").
struct ByteText: View {
    let bytes: Int64

    var body: some View {
        Text(ByteText.string(bytes))
            .monospacedDigit()
    }

    static func string(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}

#Preview {
    VStack(alignment: .trailing) {
        ByteText(bytes: 409_000_000_000)
        ByteText(bytes: 13_500_000)
    }
    .padding()
}
