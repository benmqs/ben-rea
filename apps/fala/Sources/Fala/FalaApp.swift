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
        Button(controller.state.isMeeting ? "Stop meeting recording" : "Record a meeting") {
            controller.toggleMeeting()
        }
        .disabled({ if case .meetingProcessing = controller.state { return true } else { return false } }())
        Button("Open meeting notes folder") {
            let folder = URL.documentsDirectory.appending(path: "Fala/Meetings", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(controller.lastMeetingFolder ?? folder)
        }
        Divider()
        Text("Hold \(controller.settings.hotkey.label) to dictate")
        SettingsLink { Text("Settings…") }
        Button("Quit Fala") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
