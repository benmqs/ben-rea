import AppKit
import SwiftUI

/// The floating bubble at the bottom of the screen. It is always there: a small resting pill
/// when idle that you can click to dictate, and an expanded pill while listening, working or
/// recording a meeting. It never takes focus, so the app you're typing in stays active.
final class BubblePanel {
    private let panel: NSPanel
    private let size = NSSize(width: 340, height: 64)

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        // Fully transparent areas of the panel let clicks through to the windows below.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: BubbleView().environmentObject(controller))

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.position() }
    }

    func show() {
        position()
        panel.orderFrontRegardless()
    }

    /// Moves the bubble to the screen the mouse is on.
    func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 10))
    }
}

private enum Palette {
    static let body = Color(red: 0.08, green: 0.09, blue: 0.13)
    static let listening = Color(red: 0.36, green: 0.85, blue: 0.67)
    static let recording = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let working = Color(red: 0.55, green: 0.62, blue: 1.0)
    static let warning = Color.orange
}

struct BubbleView: View {
    @EnvironmentObject var controller: DictationController
    @State private var hovering = false

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            content
                .contextMenu { BubbleMenu() }
                .onHover { hovering = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: controller.state)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .idle:
            if hovering {
                pill(accent: Palette.working) {
                    Image(systemName: "mic.fill").foregroundStyle(Palette.working)
                    label("Click or hold \(controller.settings.hotkey.label) to dictate")
                }
                .onTapGesture { controller.toggleDictation() }
            } else {
                // Resting state: a small, quiet pill so you always know Fala is running.
                Capsule()
                    .fill(Palette.body.opacity(0.75))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .frame(width: 44, height: 10)
                    .padding(8) // larger hit area for hover and click
                    .contentShape(Rectangle())
                    .onTapGesture { controller.toggleDictation() }
            }

        case .listening:
            pill(accent: Palette.listening) {
                circleButton("xmark", tint: .white.opacity(0.85), help: "Cancel") { controller.cancelDictation() }
                LevelBars(level: controller.level, color: Palette.listening)
                label("Listening…")
                circleButton("checkmark", tint: Palette.listening, help: "Finish and paste") { controller.toggleDictation() }
            }

        case .meetingRecording:
            pill(accent: Palette.recording) {
                Circle().fill(Palette.recording).frame(width: 9, height: 9)
                label(controller.state.bubbleLabel)
                circleButton("stop.fill", tint: Palette.recording, help: "Stop and transcribe") { controller.toggleMeeting() }
            }

        case .loadingModel, .transcribing, .cleaning, .meetingProcessing:
            pill(accent: Palette.working) {
                ProgressView().controlSize(.small).tint(.white)
                label(controller.state.bubbleLabel)
            }

        case .done:
            pill(accent: Palette.listening) {
                Image(systemName: "checkmark").foregroundStyle(Palette.listening)
                label(controller.state.bubbleLabel)
            }

        case .error:
            pill(accent: Palette.warning) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                label(controller.state.bubbleLabel)
            }

        case .needsPermission(let permission):
            pill(accent: Palette.warning) {
                Image(systemName: "lock.fill").foregroundStyle(Palette.warning)
                label(permission.message)
                Button("Open") { permission.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Palette.warning)
            }
        }
    }

    private func pill<Content: View>(accent: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Capsule().fill(Palette.body.opacity(0.94)))
            .overlay(Capsule().strokeBorder(accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(.bottom, 6)
            .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func circleButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Right-click menu on the bubble: everything the menu bar icon offers, for when that icon
/// is hidden behind the notch.
struct BubbleMenu: View {
    @EnvironmentObject var controller: DictationController

    var body: some View {
        Button(controller.state.isMeeting ? "Stop meeting recording" : "Record a meeting") {
            controller.toggleMeeting()
        }
        Button("Open meeting notes folder") { controller.openMeetingsFolder() }
        if let last = controller.lastText, !last.isEmpty {
            Button("Copy last dictation") { Clipboard.set(last) }
        }
        Divider()
        Button("Settings…") { AppActions.openSettings() }
        Button("Quit Fala") { NSApp.terminate(nil) }
    }
}

enum AppActions {
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// Seven bars whose heights follow the microphone level.
struct LevelBars: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.35, 0.6, 0.85, 1.0, 0.85, 0.6, 0.35]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 4 + 16 * CGFloat(level) * weights[i])
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
    }
}
