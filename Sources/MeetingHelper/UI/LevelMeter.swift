import SwiftUI

struct LevelMeter: View {
    let title: String
    let level: Float
    let isActive: Bool

    private var normalized: Double {
        // RMS of speech sits well below 1.0, so compress the useful range into the full bar.
        Double(min(1, max(0, level * 12)))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(isActive ? Color.accentColor : Color.secondary)
                        .frame(width: geometry.size.width * normalized)
                        .animation(.linear(duration: 0.1), value: normalized)
                }
            }
            .frame(height: 6)
        }
    }
}
