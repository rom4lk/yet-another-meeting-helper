import SwiftUI

/// Shared transcript renderer for the detail view and the floating panel.
struct TranscriptView: View {
    let lines: [TranscriptLine]
    var compact = false
    var autoScroll = false

    private let bottomAnchorID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 6 : 10) {
                    ForEach(lines) { line in
                        TranscriptRow(line: line, compact: compact)
                            .id(line.id)
                    }

                    Color.clear
                        .frame(height: compact ? 10 : 16)
                        .id(bottomAnchorID)
                }
                .padding([.top, .horizontal], compact ? 10 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.last) { _, line in
                guard autoScroll, line != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let line: TranscriptLine
    let compact: Bool

    private var color: Color {
        line.source == .me ? .accentColor : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.source.title)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(line.timestamp)
                    .font(.system(size: compact ? 10 : 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(line.text)
                .font(.system(size: compact ? 12 : 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
