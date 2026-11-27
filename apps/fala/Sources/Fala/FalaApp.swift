import AppKit
import SwiftUI

@main
struct FalaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Fala", systemImage: "waveform") {
            MenuContent()
                .environmentObject(delegate.controller)
        }
        Settings {
            SettingsView()
                .environmentObject(delegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, never steals focus from the app being typed into.
        NSApp.setActivationPolicy(.accessory)
        Permissions.requestAccessibilityIfNeeded()
        controller.start()
    }
}

struct MenuContent: View {
    @EnvironmentObject var controller: DictationController

    var body: some View {
        Text(controller.state.menuLabel)
        if let last = controller.lastText, !last.isEmpty {
            Button("Copy last dictation") { Clipboard.set(last) }
        }
        Divider()
        Text("Hold \(controller.settings.hotkey.label) to dictate")
        SettingsLink { Text("Settings…") }
        Button("Quit Fala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
