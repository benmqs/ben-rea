import AppKit
import SwiftUI

/// Hover state and measured pill size, shared between the AppKit panel and the SwiftUI view.
final class BubbleModel: ObservableObject, @unchecked Sendable {
    @Published var hovering = false
    var onSize: @MainActor (CGSize) -> Void = { _ in }

    /// Safe to call from any context (onPreferenceChange is @Sendable on recent SDKs).
    func report(_ size: CGSize) {
        Task { @MainActor in self.onSize(size) }
    }
}

private struct BubbleSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Hosting view that reports hover from AppKit (works while Fala is not the active app)
/// and accepts the first click.
private final class BubbleHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover(false) }
    }
}

/// The floating bubble at the bottom centre of the screen. The panel is always exactly as big
/// as what is drawn, so it never blocks clicks on the windows around it, and it never takes focus.
@MainActor
final class BubblePanel {
    private let panel: NSPanel
    private let model = BubbleModel()
    private var contentSize = NSSize(width: 84, height: 36)
    private var screen: NSScreen?
    private var shrinkTask: Task<Void, Never>?

    init(controller: DictationController) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false   // NSPanel defaults to true: the bubble would vanish
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = BubbleHostingView(
            rootView: BubbleView().environmentObject(controller).environmentObject(model)
        )
        host.sizingOptions = []           // the window is sized by resize(to:)
        host.onHover = { [weak self] inside in self?.setHovering(inside) }
        panel.contentView = host
        model.onSize = { [weak self] size in self?.resize(to: size) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let current = self.screen, !NSScreen.screens.contains(current) { self.screen = nil }
                self.layout()
            }
        }
    }

    func show() {
        position()
        panel.orderFrontRegardless()
    }

    /// Moves the bubble to the screen the mouse is on.
    func position() {
        screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        layout()
    }

    private func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        shrinkTask?.cancel()
        if size.width > contentSize.width || size.height > contentSize.height {
            contentSize = NSSize(width: max(size.width, contentSize.width),
                                 height: max(size.height, contentSize.height))
            layout()
        }
        if size != contentSize {
            // Shrink after the exit animation, so it is not clipped by the smaller window.
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.contentSize = size
                self.layout()
            }
        }
    }

    private func layout() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let width = min(ceil(contentSize.width), visible.width - 40)
        let height = ceil(contentSize.height)
        let frame = NSRect(x: (visible.midX - width / 2).rounded(), y: visible.minY + 6,
                           width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // A resize under a still mouse sends no enter/exit event, so resync.
        setHovering(frame.contains(NSEvent.mouseLocation))
    }

    private func setHovering(_ inside: Bool) {
        if model.hovering != inside { model.hovering = inside }
    }
}

// MARK: - Look

/// Monochrome: a black pill with white marks, the way dictation pills usually look.
private enum Look {
    static let body = Color.black.opacity(0.92)
    static let edge = Color.white.opacity(0.22)
    static let mark = Color.white
    static let dim = Color.white.opacity(0.6)
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let font = Font.system(size: 12.5, weight: .medium)
}

struct BubbleView: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var model: BubbleModel

    var body: some View {
        VStack(spacing: 7) {
            if let hint { HintToast(text: hint) }
            pill
        }
        .contextMenu { BubbleMenu() }
        .padding(.horizontal, 12)
        .padding(.top, 10)            // room for the shadow
        .padding(.bottom, 2)
        .fixedSize()
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BubbleSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(BubbleSizeKey.self) { [model] size in model.report(size) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: controller.state)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: controller.handsFree)
        .animation(.easeOut(duration: 0.15), value: model.hovering)
    }

    /// The small dark toast above the pill.
    private var hint: String? {
        switch controller.state {
        case .idle where model.hovering:
            return "Click or hold \(controller.settings.hotkey.label) to start dictating"
        case .listening where controller.handsFree:
            return "Click ✓ to finish and paste"
        case .loadingModel, .meetingProcessing, .done, .error, .needsPermission:
            return controller.state.bubbleLabel
        case .meetingRecording where model.hovering:
            return "Recording meeting. Click ■ to stop and transcribe"
        default:
            return nil
        }
    }

    @ViewBuilder private var pill: some View {
        switch controller.state {
        case .idle:
            if model.hovering {
                capsule(height: 26) { Dots(count: 9, color: Look.dim) }
                    .onTapGesture { controller.toggleDictation() }
            } else {
                // Resting: a small, quiet pill so you always know where to click.
                Capsule()
                    .fill(Look.body)
                    .overlay(Capsule().strokeBorder(Look.edge, lineWidth: 1))
                    .frame(width: 42, height: 9)
                    .padding(.horizontal, 10).padding(.top, 8)   // larger target for hover and click
                    .contentShape(Rectangle())
                    .onTapGesture { controller.toggleDictation() }
            }

        case .listening:
            capsule(height: 32) {
                if controller.handsFree {
                    roundButton("xmark", fill: .white.opacity(0.22), mark: Look.mark, help: "Cancel") {
                        controller.cancelDictation()
                    }
                }
                LevelBars(level: controller.level, color: Look.mark)
                    .padding(.horizontal, controller.handsFree ? 2 : 8)
                if controller.handsFree {
                    roundButton("checkmark", fill: Look.mark, mark: .black, help: "Finish and paste") {
                        controller.toggleDictation()
                    }
                }
            }

        case .transcribing, .cleaning, .loadingModel, .meetingProcessing:
            capsule(height: 26) { Dots(count: 5, color: Look.mark, animated: true) }
                .onTapGesture { controller.toggleDictation() }

        case .meetingRecording:
            capsule(height: 32) {
                Circle().fill(Look.recording).frame(width: 8, height: 8).padding(.leading, 6)
                Text(controller.state.bubbleLabel)
                    .font(Look.font.monospacedDigit())
                    .foregroundStyle(Look.mark)
                roundButton("stop.fill", fill: Look.mark, mark: .black, help: "Stop and transcribe") {
                    controller.toggleMeeting()
                }
            }

        case .done:
            capsule(height: 26) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Look.mark)
                    .padding(.horizontal, 8)
            }
            .onTapGesture { controller.toggleDictation() }

        case .error:
            capsule(height: 26) {
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Look.warning).padding(.horizontal, 10)
            }
            .onTapGesture { controller.toggleDictation() }

        case .needsPermission(let permission):
            capsule(height: 32) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Look.warning)
                    .padding(.leading, 8)
                Button("Open Settings") { permission.openSettings() }
                    .buttonStyle(.plain)
                    .font(Look.font)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(Look.mark))
            }
        }
    }

    private func capsule<Content: View>(height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 5)
            .frame(minWidth: 64, minHeight: height, maxHeight: height)
            .background(Capsule().fill(Look.body))
            .overlay(Capsule().strokeBorder(Look.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .contentShape(Capsule())
            .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
    }

    private func roundButton(_ symbol: String, fill: Color, mark: Color, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(mark)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Dark rounded toast shown above the pill.
struct HintToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Look.font)
            .foregroundStyle(Look.mark)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Look.body))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Look.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// A row of small dots: static as a "click me" texture, or pulsing while working.
struct Dots: View {
    let count: Int
    let color: Color
    var animated = false
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
                    .opacity(animated ? (i == phase % count ? 1 : 0.3) : 1)
            }
        }
        .padding(.horizontal, 8)
        .task(id: animated) {
            guard animated else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(140))
                phase += 1
            }
        }
    }
}

/// White bars whose heights follow the microphone level.
struct LevelBars: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.3, 0.5, 0.75, 0.95, 0.65, 1.0, 0.8, 0.55, 0.9, 0.6, 0.35]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: 3 + 17 * CGFloat(level) * weights[i])
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
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
        Button("Settings…") { AppActions.openSettings(controller: controller) }
        Button("Quit Fala") { NSApp.terminate(nil) }
    }
}

@MainActor
enum AppActions {
    private static var settingsWindow: NSWindow?

    /// Opens our own settings window: the SwiftUI Settings scene cannot be opened from
    /// AppKit on macOS 14+, and SettingsLink opens it behind other apps for an accessory app.
    static func openSettings(controller: DictationController) {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView().environmentObject(controller)))
            window.title = "Fala Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
