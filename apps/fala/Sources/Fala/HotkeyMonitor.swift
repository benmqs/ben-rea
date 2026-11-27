import AppKit

/// Watches a single modifier key held on its own (push-to-talk).
/// Global monitoring of keys needs the Accessibility permission.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// The key turned out to be a modifier for another key (Option+E, Cmd+C…).
    var onCancel: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private let keyCodeProvider: () -> UInt16

    init(keyCode: @escaping () -> UInt16) {
        self.keyCodeProvider = keyCode
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] in
            self?.handle($0)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] in
            self?.handle($0)
            return $0
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            // An ordinary key while the hotkey is held: it is being used as a modifier.
            if isDown {
                isDown = false
                onCancel()
            }
            return
        }
        guard event.keyCode == keyCodeProvider() else { return }
        let pressed = isPressed(event)
        if pressed && !isDown {
            isDown = true
            onPress()
        } else if !pressed && isDown {
            isDown = false
            onRelease()
        }
    }

    private func isPressed(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 61, 58: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        case 63: return flags.contains(.function)
        default: return false
        }
    }
}
