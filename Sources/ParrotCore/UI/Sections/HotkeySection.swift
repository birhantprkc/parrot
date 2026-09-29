import SwiftUI

/// The push-to-talk key (#42).
struct HotkeySection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section("Hotkey") {
            Picker("Hold to dictate", selection: Binding(
                get: { store.current.hotkey.key },
                set: { key in store.update { $0.hotkey.key = key } }
            )) {
                ForEach(HotkeyKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }
            Text("fn doesn't reach macOS on many third-party keyboards; pick Right Option there. Applies from the next press.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
