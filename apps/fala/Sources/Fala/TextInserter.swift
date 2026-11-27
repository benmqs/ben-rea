import AppKit
import ApplicationServices

enum Clipboard {
    static func set(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

enum Permission: Equatable {
    case accessibility, microphone

    var message: String {
        switch self {
        case .accessibility: "Turn on Accessibility for Fala"
        case .microphone: "Allow microphone access for Fala"
        }
    }

    func openSettings() {
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
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

/// Everything on the pasteboard (all items, all types), so images, files and rich text survive a paste.
struct ClipboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pb: NSPasteboard) {
        items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        })
    }
}

/// Puts text where the user is typing. It always pastes; the previous clipboard is restored only
/// when the focus is known to be a text field, otherwise the dictation stays on the clipboard
/// (Electron apps and canvas editors don't report their text fields, so pasting blind is right).
enum TextInserter {
    enum Outcome { case pasted, pastedKeptOnClipboard, copied }

    @MainActor
    static func insert(_ text: String) -> Outcome {
        guard Permissions.hasAccessibility else {
            Clipboard.set(text)
            return .copied
        }

        let pb = NSPasteboard.general
        let saved = focusedElementIsText() ? ClipboardSnapshot(pb) : nil
        Clipboard.set(text)
        let ours = pb.changeCount
        sendCommandV()
        guard let saved else { return .pastedKeptOnClipboard }

        // Restore the previous clipboard off the critical path, after the target app has had
        // time to read the pasteboard, and only if nothing else was copied meanwhile.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pb.changeCount == ours { saved.restore(to: pb) }
        }
        return .pasted
    }

    /// True only when the focused element is positively a text field. Unknown (Electron, canvas
    /// editors, a busy app) is false: the caller still pastes but keeps the text on the clipboard.
    private static func focusedElementIsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return false
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
        return AXUIElementIsAttributeSettable(ax, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
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
