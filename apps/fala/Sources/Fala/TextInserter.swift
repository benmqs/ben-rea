import AppKit
import ApplicationServices

enum Clipboard {
    static func set(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Puts text where the user is typing. If a text field has focus, it pastes there and then
/// restores the previous clipboard; otherwise it only copies, so nothing is lost.
enum TextInserter {
    enum Outcome { case pasted, copied }

    @MainActor
    static func insert(_ text: String) async -> Outcome {
        guard Permissions.hasAccessibility, focusedElementAcceptsText() else {
            Clipboard.set(text)
            return .copied
        }

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        Clipboard.set(text)
        sendCommandV()

        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(400))
        if let previous, pb.string(forType: .string) == text {
            Clipboard.set(previous)
        }
        return .pasted
    }

    private static func focusedElementAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            // Some apps (Electron, games) don't expose focus. Pasting is harmless there, so try it.
            return true
        }
        let ax = element as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = [
            kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
        ]
        if let role = role as? String, textRoles.contains(role) { return true }

        // Web views and custom editors: editable if the selected range can be set.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(ax, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
