import SwiftUI

/// The push-to-talk key (#42), a row in the General section.
struct HotkeyRow: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Picker("Hotkey", selection: Binding(
            get: { store.current.hotkey.key },
            set: { key in store.update { $0.hotkey.key = key } }
        )) {
            ForEach(HotkeyKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }
    }
}
