import AppKit
import SwiftUI

/// Content of the always-on-top panel.
struct FloatingTranscriptView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let session = controller.session {
                if session.sortedLines.isEmpty {
                    placeholder(for: session)
                } else {
                    TranscriptView(lines: session.sortedLines, compact: true, autoScroll: true)
                }
            } else {
                Text("Not recording")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            BottomResizeHandle()
                .frame(maxWidth: .infinity, minHeight: 12, maxHeight: 12)
        }
        .background(.ultraThinMaterial)
        .frame(minWidth: 320, minHeight: 180)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if controller.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            }

            Text(controller.session?.title ?? "Meetings Helper")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let session = controller.session {
                Text(Self.format(session.elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    controller.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop recording")
            }

            Button {
                controller.hidePanel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide the panel (⌥⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func placeholder(for session: RecordingSession) -> some View {
        VStack(spacing: 6) {
            switch session.transcriptionState {
            case .downloading(let progress):
                ProgressView(value: progress ?? 0)
                    .controlSize(.small)
                    .frame(width: 100)
                Text(progress.map {
                    "Downloading model — \($0.formatted(.percent.precision(.fractionLength(0))))"
                } ?? "Starting model download…")
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing speech recognition…")
            case .running:
                Text("Listening…")
            case .disabled:
                Text("Live transcript is off in Settings")
            case .failed(let message):
                Text("Recognition error")
                Text(message).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct BottomResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> BottomResizeHandleView {
        BottomResizeHandleView()
    }

    func updateNSView(_ nsView: BottomResizeHandleView, context: Context) {}
}

private final class BottomResizeHandleView: NSView {
    private var initialWindowFrame: NSRect?
    private var initialMouseY: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag to resize the panel"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialWindowFrame = window.frame
        initialMouseY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let initialWindowFrame,
            let initialMouseY
        else { return }

        let mouseDelta = NSEvent.mouseLocation.y - initialMouseY
        let proposedHeight = initialWindowFrame.height - mouseDelta
        let maximumHeight = max(
            window.minSize.height,
            initialWindowFrame.maxY - (window.screen?.visibleFrame.minY ?? 0)
        )
        let newHeight = min(maximumHeight, max(window.minSize.height, proposedHeight))
        let newFrame = NSRect(
            x: initialWindowFrame.minX,
            y: initialWindowFrame.maxY - newHeight,
            width: initialWindowFrame.width,
            height: newHeight
        )
        window.setFrame(newFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        initialWindowFrame = nil
        initialMouseY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let indicatorRect = NSRect(
            x: bounds.midX - 18,
            y: bounds.midY - 1,
            width: 36,
            height: 2
        )
        NSColor.separatorColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: indicatorRect, xRadius: 1, yRadius: 1).fill()
    }
} 
