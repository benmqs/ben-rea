import Foundation
import Security
import ServiceManagement
import SwiftUI

enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, fn

    var id: String { rawValue }

    /// Virtual key codes reported in flagsChanged events.
    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        }
    }

    var label: String {
        switch self {
        case .rightOption: "Right Option ⌥"
        case .rightCommand: "Right Command ⌘"
        case .fn: "Fn"
        }
    }
}

enum SpokenLanguage: String, CaseIterable, Identifiable {
    case auto, pt, en, es

    var id: String { rawValue }

    /// Whisper language code, or nil to auto-detect.
    var whisperCode: String? { self == .auto ? nil : rawValue }

    var label: String {
        switch self {
        case .auto: "Auto-detect"
        case .pt: "Português"
        case .en: "English"
        case .es: "Español"
        }
    }
}

/// User preferences. Plain values live in UserDefaults; the API key lives in the Keychain.
final class AppSettings: ObservableObject {
    @AppStorage("hotkey") var hotkey: Hotkey = .rightOption
    @AppStorage("language") var language: SpokenLanguage = .auto
    @AppStorage("whisperModel") var whisperModel: String = "openai_whisper-large-v3-v20240930_turbo"
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("cleanupModel") var cleanupModel: String = "claude-haiku-5-5"
    /// Names, brands and jargon Whisper and the cleanup step should spell correctly, one per line.
    @AppStorage("vocabulary") var vocabulary: String = ""

    private var cachedKey: String?

    /// Cached after the first read, trimmed on write (a pasted trailing newline would break the header).
    var anthropicKey: String {
        get {
            if let cachedKey { return cachedKey }
            let stored = Keychain.read("anthropic-api-key") ?? ""
            cachedKey = stored
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != cachedKey else { return }
            cachedKey = trimmed
            Keychain.write("anthropic-api-key", trimmed)
            objectWillChange.send()
        }
    }

    var vocabularyList: [String] {
        vocabulary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

enum Keychain {
    private static let service = "app.fala.dictation"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var controller: DictationController
    @AppStorage("hotkey") private var hotkey: Hotkey = .rightOption
    @AppStorage("language") private var language: SpokenLanguage = .auto
    @AppStorage("whisperModel") private var whisperModel = "openai_whisper-large-v3-v20240930_turbo"
    @AppStorage("cleanupEnabled") private var cleanupEnabled = true
    @AppStorage("cleanupModel") private var cleanupModel = "claude-haiku-5-5"
    @AppStorage("vocabulary") private var vocabulary = ""
    @State private var key = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private static let speechModels: [(id: String, name: String)] = [
        ("openai_whisper-small", "Fastest (small)"),
        ("openai_whisper-large-v3-v20240930_turbo_632MB", "Balanced (large v3 turbo, compressed)"),
        ("openai_whisper-large-v3-v20240930_turbo", "Most accurate (large v3 turbo)"),
    ]

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: $hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: $language) {
                    ForEach(SpokenLanguage.allCases) { Text($0.label).tag($0) }
                }
                Picker("Speech model", selection: $whisperModel) {
                    ForEach(Self.speechModels, id: \.id) { Text($0.name).tag($0.id) }
                    if !Self.speechModels.contains(where: { $0.id == whisperModel }) {
                        Text(whisperModel).tag(whisperModel)   // keep a custom value selectable
                    }
                }
                .onChange(of: whisperModel) { _, model in controller.preloadModel(model) }
                Text("A new model is downloaded as soon as you pick it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clean-up with Claude") {
                Toggle("Clean up text before pasting", isOn: $cleanupEnabled)
                Picker("Model", selection: $cleanupModel) {
                    Text("Claude Haiku 5.5 (fast, about $0.0001 per dictation)").tag("claude-haiku-5-5")
                    Text("Claude Opus 5.5 (most careful, slower, about $0.005)").tag("claude-opus-5-5")
                }
                SecureField("Anthropic API key", text: $key)
                    .onChange(of: key) { _, value in controller.settings.anthropicKey = value }
                Text(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No key: text is pasted without clean-up."
                     : "Saved in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Personal vocabulary (one per line)") {
                TextEditor(text: $vocabulary).frame(minHeight: 80)
            }
            Section("General") {
                Toggle("Open Fala at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        guard on != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Fala login item: %@", String(describing: error))
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onAppear { key = controller.settings.anthropicKey }
    }
}
