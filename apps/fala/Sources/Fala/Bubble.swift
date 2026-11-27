import AppKit
import SwiftUI

/// A small always-on-top pill near the bottom of the screen that shows what Fala is doing.
/// It never takes focus, so the app you're typing in stays active.
final class BubblePanel {
    private let panel: NSPanel
    private let size = NSSize(width: 220, height: 44)

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BubbleView().environmentObject(controller))
    }

    func show() {
        position()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }
}

struct BubbleView: View {
    @EnvironmentObject var controller: DictationController

    var body: some View {
        HStack(spacing: 10) {
            indicator
            Text(controller.state.bubbleLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Color(red: 0.09, green: 0.10, blue: 0.14).opacity(0.92)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: controller.state)
    }

    private var accent: Color {
        switch controller.state {
        case .listening: Color(red: 0.36, green: 0.85, blue: 0.67)
        case .error: .orange
        default: Color(red: 0.55, green: 0.62, blue: 1.0)
        }
    }

    @ViewBuilder private var indicator: some View {
        switch controller.state {
        case .listening:
            LevelBars(level: controller.level, color: accent)
        case .transcribing, .cleaning, .loadingModel:
            ProgressView().controlSize(.small).tint(.white)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(accent)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(accent)
        case .idle:
            EmptyView()
        }
    }
}

/// Five bars whose heights follow the microphone level.
struct LevelBars: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 14 * CGFloat(level) * weights[i])
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }
}
