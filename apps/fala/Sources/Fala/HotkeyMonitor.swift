import AppKit

/// Watches a single modifier key held on its own (push-to-talk).
/// Global monitoring of modifier keys needs the Accessibility permission.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private let keyCodeProvider: () -> UInt16

    init(keyCode: @escaping () -> UInt16) {
        self.keyCodeProvider = keyCode
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in
            self?.handle($0)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in
            self?.handle($0)
            return $0
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCodeProvider() else {
            // Another modifier joined in (e.g. Option+Shift shortcut): cancel nothing, just ignore.
            return
        }
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
