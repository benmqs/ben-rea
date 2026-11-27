import AppKit
import SwiftUI

/// Where the pill rests: bottom centre, or the middle of the left or right edge.
enum BubbleDock: String, Sendable {
    case bottom, left, right
}

/// Parts of the pill the mouse can be over. `pill` is the whole pill.
enum HoverTarget: Hashable, Sendable {
    case pill, dictate, meeting, cancel, confirm, stop
}

/// State shared between the AppKit panel and the SwiftUI views.
final class BubbleModel: ObservableObject, @unchecked Sendable {
    @Published var hovered: Set<HoverTarget> = []
    @Published var dock = BubbleDock(rawValue: UserDefaults.standard.string(forKey: "bubbleDock") ?? "") ?? .bottom
    /// True while the pill is being dragged to another dock (and a moment after, to swallow the click).
    @Published var dragging = false
    /// The dock the pill would land on if the drag ended now.
    @Published var dropTarget = BubbleDock.bottom
    /// Space taken by the Dock and menu bar on the dragged-over screen: bottom, left, right.
    @Published var insets: (bottom: CGFloat, left: CGFloat, right: CGFloat) = (0, 0, 0)

    /// Frames of the hover targets in panel coordinates (top-left origin), written by SwiftUI layout.
    var frames: [HoverTarget: CGRect] = [:]

    /// Safe to call from any context (onPreferenceChange is @Sendable on recent SDKs).
    func report(_ frames: [HoverTarget: CGRect]) {
        Task { @MainActor in self.frames = frames }
    }
}

private struct HoverFramesKey: PreferenceKey {
    static let defaultValue: [HoverTarget: CGRect] = [:]
    static func reduce(value: inout [HoverTarget: CGRect], nextValue: () -> [HoverTarget: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Registers this view's frame so the panel can tell when the mouse is over it.
    func hoverTarget(_ target: HoverTarget, pad: CGFloat = 0) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(
                key: HoverFramesKey.self,
                value: [target: proxy.frame(in: .named("bubble")).insetBy(dx: -pad, dy: -pad)])
        })
    }
}

/// Hosting view that takes the first click even though Fala is never the active app.
private final class BubbleHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill's window. It watches mouse drags so the pill can be moved to another dock,
/// and otherwise passes every event on untouched.
private final class BubbleWindow: NSPanel {
    var onDragStart: () -> Void = {}
    var onDragMove: (NSPoint) -> Void = { _ in }
    var onDragEnd: (NSPoint) -> Void = { _ in }
    private var downAt: NSPoint?
    private var dragging = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downAt = NSEvent.mouseLocation
            dragging = false
        case .leftMouseDragged:
            if let downAt {
                let mouse = NSEvent.mouseLocation
                if !dragging, hypot(mouse.x - downAt.x, mouse.y - downAt.y) > 6 {
                    dragging = true
                    onDragStart()
                }
                if dragging {
                    onDragMove(mouse)
                    return
                }
            }
        case .leftMouseUp:
            downAt = nil
            if dragging {
                dragging = false
                super.sendEvent(event)      // lets SwiftUI finish its own tracking
                onDragEnd(NSEvent.mouseLocation)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// The floating pill. Its window has a fixed size and is transparent; it ignores the mouse
/// except while the pointer is over the pill itself, so it never blocks the windows around it,
/// and it never takes focus.
@MainActor
final class BubblePanel {
    private static let size = NSSize(width: 480, height: 130)
    private static let margin: CGFloat = 3

    private let panel: BubbleWindow
    private let overlay: NSPanel
    private let model = BubbleModel()
    private weak var controller: DictationController?
    private var screen: NSScreen?
    private var timer: Timer?

    init(controller: DictationController) {
        self.controller = controller
        panel = BubbleWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        overlay = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        for window in [panel, overlay] {
            window.isFloatingPanel = true
            window.level = .statusBar
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.hidesOnDeactivate = false   // NSPanel defaults to true: the pill would vanish
            window.becomesKeyOnlyIfNeeded = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }

        let host = BubbleHostingView(
            rootView: BubbleView().environmentObject(controller).environmentObject(model)
        )
        host.sizingOptions = []
        panel.contentView = host
        let overlayHost = NSHostingView(rootView: DockOverlayView().environmentObject(model))
        overlayHost.sizingOptions = []
        overlay.contentView = overlayHost

        panel.onDragStart = { [weak self] in self?.dragStarted() }
        panel.onDragMove = { [weak self] in self?.dragMoved(to: $0) }
        panel.onDragEnd = { [weak self] in self?.dragEnded(at: $0) }

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
        guard timer == nil else { return }
        // Polling the pointer is the only hover signal that works for a window that ignores
        // the mouse, and it also lets the pill follow the pointer to another display.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Moves the pill to the screen the mouse is on.
    func position() {
        screen = Self.screen(at: NSEvent.mouseLocation) ?? NSScreen.main
        layout()
    }

    private static func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func layout() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = Self.size
        let origin: NSPoint
        switch model.dock {
        case .bottom: origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + Self.margin)
        case .left: origin = NSPoint(x: visible.minX + Self.margin, y: visible.midY - size.height / 2)
        case .right: origin = NSPoint(x: visible.maxX - size.width - Self.margin, y: visible.midY - size.height / 2)
        }
        let frame = NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func tick() {
        guard !model.dragging else { return }
        let mouse = NSEvent.mouseLocation

        // Follow the display in use, but never jump in the middle of a dictation or a meeting.
        if controller?.state.isResting == true, NSEvent.pressedMouseButtons == 0,
           let current = Self.screen(at: mouse), current != screen {
            screen = current
            layout()
        }

        var hovered: Set<HoverTarget> = []
        let frame = panel.frame
        if frame.contains(mouse) {
            let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
            for (target, rect) in model.frames where rect.contains(local) { hovered.insert(target) }
        }
        if hovered != model.hovered { model.hovered = hovered }
        let ignore = !hovered.contains(.pill)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    // MARK: Dragging to another dock

    private func dragStarted() {
        model.dragging = true
        model.hovered = []
        dragMoved(to: NSEvent.mouseLocation)
        overlay.orderFront(nil)
        panel.orderFrontRegardless()
    }

    private func dragMoved(to mouse: NSPoint) {
        guard let target = Self.screen(at: mouse) ?? screen ?? NSScreen.main else { return }
        let frame = target.frame, visible = target.visibleFrame
        if overlay.frame != frame { overlay.setFrame(frame, display: true) }
        model.insets = (visible.minY - frame.minY, visible.minX - frame.minX, frame.maxX - visible.maxX)

        func distance(_ x: CGFloat, _ y: CGFloat) -> CGFloat { hypot(mouse.x - x, mouse.y - y) }
        let candidates: [(BubbleDock, CGFloat)] = [
            (.bottom, distance(visible.midX, visible.minY)),
            (.left, distance(visible.minX, visible.midY)),
            (.right, distance(visible.maxX, visible.midY)),
        ]
        let nearest = candidates.min { $0.1 < $1.1 }?.0 ?? .bottom
        if model.dropTarget != nearest { model.dropTarget = nearest }
    }

    private func dragEnded(at mouse: NSPoint) {
        dragMoved(to: mouse)
        overlay.orderOut(nil)
        model.dock = model.dropTarget
        UserDefaults.standard.set(model.dock.rawValue, forKey: "bubbleDock")
        screen = Self.screen(at: mouse) ?? screen
        layout()
        // The mouse-up that ended the drag must not count as a click on the pill.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.model.dragging = false
        }
    }
}

// MARK: - Look

/// Monochrome: a black pill with white marks, the way dictation pills usually look.
private enum Look {
    static let body = Color.black.opacity(0.92)
    static let edge = Color.white.opacity(0.28)
    static let mark = Color.white
    static let dim = Color.white.opacity(0.6)
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let font = Font.system(size: 12.5, weight: .medium)
    static let spring = Animation.spring(response: 0.26, dampingFraction: 0.84)
}

struct BubbleView: View {
    @EnvironmentObject var controller: DictationController
    @EnvironmentObject var model: BubbleModel

    private var hot: Bool { model.hovered.contains(.pill) }
    private var vertical: Bool { model.dock != .bottom }

    var body: some View {
        arranged
            .padding(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .coordinateSpace(name: "bubble")
            .onPreferenceChange(HoverFramesKey.self) { [model] frames in model.report(frames) }
            .opacity(model.dragging ? 0 : 1)
            .ignoresSafeArea()
            .animation(Look.spring, value: controller.state)
            .animation(Look.spring, value: model.hovered)
            .animation(Look.spring, value: model.dock)
    }

    private var alignment: Alignment {
        switch model.dock {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// The toast sits above the pill at the bottom dock, and beside it at the side docks.
    @ViewBuilder private var arranged: some View {
        switch model.dock {
        case .bottom: VStack(spacing: 5) { toast; target }
        case .left: HStack(spacing: 6) { target; toast }
        case .right: HStack(spacing: 6) { toast; target }
        }
    }

    @ViewBuilder private var toast: some View {
        if let hint { HintToast(text: hint) }
    }

    private var target: some View {
        pill
            .padding(5)                       // a slightly larger target for hover and right-click
            .contentShape(Rectangle())
            .hoverTarget(.pill)
            .contextMenu { BubbleMenu() }
    }

    /// Runs a click, unless it is the mouse-up that ended a drag.
    private func act(_ action: () -> Void) {
        guard !model.dragging else { return }
        action()
    }

    private var key: Text { Text(controller.settings.hotkey.label).bold().foregroundColor(Look.mark) }

    /// The small dark toast next to the pill.
    private var hint: Text? {
        switch controller.state {
        case .idle where model.hovered.contains(.meeting):
            return Text("Record a meeting")
        case .idle where hot:
            return Text("Dictate  ").foregroundColor(Look.dim) + key
        case .listening where model.hovered.contains(.cancel):
            return Text("Cancel")
        case .listening where model.hovered.contains(.confirm):
            return Text("Finish and paste")
        case .listening where hot:
            return Text(controller.handsFree ? "Press " : "Release ").foregroundColor(Look.dim) + key
                + Text(" to finish and paste").foregroundColor(Look.dim)
        case .meetingRecording where hot:
            return Text(model.hovered.contains(.stop) ? "Stop and write the notes" : "Recording meeting")
        case .transcribing where hot, .cleaning where hot:
            return Text(controller.state.bubbleLabel)
        case .loadingModel, .meetingProcessing, .done, .error, .needsPermission:
            return Text(controller.state.bubbleLabel)
        default:
            return nil
        }
    }

    @ViewBuilder private var pill: some View {
        switch controller.state {
        case .idle:
            if hot {
                // Two buttons: dictate, and record a meeting.
                let layout = vertical ? AnyLayout(VStackLayout(spacing: 5)) : AnyLayout(HStackLayout(spacing: 5))
                layout {
                    Button { act { controller.toggleDictation() } } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Look.mark)
                            .frame(width: vertical ? 28 : 36, height: vertical ? 36 : 28)
                            .background(Capsule().fill(Look.body))
                            .overlay(Capsule().strokeBorder(Look.edge, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .hoverTarget(.dictate)
                    Button { act { controller.toggleMeeting() } } label: {
                        Image(systemName: "record.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Look.mark)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Look.body))
                            .overlay(Circle().strokeBorder(Look.edge, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverTarget(.meeting)
                }
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                // Resting: a small, quiet pill that is always on screen.
                Capsule()
                    .fill(Color.black.opacity(0.75))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                    .frame(width: vertical ? 8 : 40, height: vertical ? 40 : 8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

        case .listening:
            capsule(height: 32) {
                roundButton("xmark", fill: .white.opacity(0.22), mark: Look.mark) {
                    controller.cancelDictation()
                }
                .hoverTarget(.cancel)
                LevelBars(level: controller.level, color: Look.mark)
                    .padding(.horizontal, 2)
                roundButton("checkmark", fill: Look.mark, mark: .black) {
                    controller.finishDictation()
                }
                .hoverTarget(.confirm)
            }

        case .transcribing, .cleaning, .loadingModel, .meetingProcessing:
            capsule(height: 26) { Dots(count: 5, color: Look.mark, animated: true) }
                .onTapGesture { act { controller.toggleDictation() } }

        case .meetingRecording:
            capsule(height: 32) {
                Circle().fill(Look.recording).frame(width: 8, height: 8).padding(.leading, 6)
                Text(controller.state.bubbleLabel)
                    .font(Look.font.monospacedDigit())
                    .foregroundStyle(Look.mark)
                roundButton("stop.fill", fill: Look.mark, mark: .black) {
                    controller.toggleMeeting()
                }
                .hoverTarget(.stop)
            }

        case .done:
            capsule(height: 26) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Look.mark)
                    .padding(.horizontal, 8)
            }
            .onTapGesture { act { controller.toggleDictation() } }

        case .error:
            capsule(height: 26) {
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Look.warning).padding(.horizontal, 10)
            }
            .onTapGesture { act { controller.toggleDictation() } }

        case .needsPermission(let permission):
            capsule(height: 32) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Look.warning)
                    .padding(.leading, 8)
                Button("Open Settings") { act { permission.openSettings() } }
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
            .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    private func roundButton(_ symbol: String, fill: Color, mark: Color,
                             action: @escaping () -> Void) -> some View {
        Button { act(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(mark)
                .frame(width: 22, height: 22)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown over the whole screen while the pill is dragged: the three places it can rest,
/// with the nearest one lit.
struct DockOverlayView: View {
    @EnvironmentObject var model: BubbleModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            slot(.bottom, alignment: .bottom).padding(.bottom, model.insets.bottom + 8)
            slot(.left, alignment: .leading).padding(.leading, model.insets.left + 8)
            slot(.right, alignment: .trailing).padding(.trailing, model.insets.right + 8)
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.12), value: model.dropTarget)
    }

    private func slot(_ dock: BubbleDock, alignment: Alignment) -> some View {
        let active = model.dropTarget == dock
        let vertical = dock != .bottom
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(active ? 0.92 : 0.4))
            .frame(width: vertical ? 40 : 64, height: vertical ? 64 : 40)
            .scaleEffect(active ? 1.1 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// Dark rounded toast shown above the pill.
struct HintToast: View {
    let text: Text

    var body: some View {
        text
            .font(Look.font)
            .foregroundStyle(Look.mark)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Look.body))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Look.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .transition(.opacity)
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
