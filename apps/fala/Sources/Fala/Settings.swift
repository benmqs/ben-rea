import Foundation
import Security
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

    var anthropicKey: String {
        get { Keychain.read("anthropic-api-key") ?? "" }
        set {
            Keychain.write("anthropic-api-key", newValue)
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
    @State private var key: String = ""

    var body: some View {
        let s = controller.settings
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: Binding(get: { s.hotkey }, set: { s.hotkey = $0 })) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: Binding(get: { s.language }, set: { s.language = $0 })) {
                    ForEach(SpokenLanguage.allCases) { Text($0.label).tag($0) }
                }
                TextField("Whisper model", text: Binding(get: { s.whisperModel }, set: { s.whisperModel = $0 }))
                Text("Changing the model downloads it on next use.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Clean-up with Claude") {
                Toggle("Clean up text before pasting", isOn: Binding(get: { s.cleanupEnabled }, set: { s.cleanupEnabled = $0 }))
                Picker("Model", selection: Binding(get: { s.cleanupModel }, set: { s.cleanupModel = $0 })) {
                    Text("Claude Haiku 5.5 (fast, about $0.0001 per dictation)").tag("claude-haiku-5-5")
                    Text("Claude Opus 5.5 (most careful, slower, about $0.005)").tag("claude-opus-5-5")
                }
                SecureField("Anthropic API key", text: $key)
                    .onSubmit { s.anthropicKey = key }
                Button("Save key") { s.anthropicKey = key }
            }
            Section("Personal vocabulary (one per line)") {
                TextEditor(text: Binding(get: { s.vocabulary }, set: { s.vocabulary = $0 }))
                    .frame(minHeight: 80)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { key = s.anthropicKey }
    }
}
