import SwiftUI

/// The model and the spoken language (#43).
struct TranscriptionSection: View {
    @ObservedObject var store: SettingsStore

    /// Every language Whisper knows, by name in the user's language.
    private static let languages: [(code: String, name: String)] = SpokenLanguage.whisperLanguages
        .map { (code: $0, name: SpokenLanguage.displayName($0)) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var selectedModel: TranscriptionModel? {
        store.current.model.id.flatMap(ModelRegistry.find) ?? ModelRegistry.recommended()
    }

    var body: some View {
        Section("Transcription") {
            Picker("Model", selection: Binding(
                get: { selectedModel?.id ?? "" },
                set: { id in store.update { $0.model.id = id } }
            )) {
                ForEach(ModelRegistry.shared, id: \.id) { model in
                    Text("\(model.displayName) · \(model.sizeMB) MB").tag(model.id)
                }
            }

            languagePicker
        }
    }

    /// Automatic, then every language by name. A saved code Whisper does not
    /// know shows as Automatic, which is how it is treated.
    @ViewBuilder private var languagePicker: some View {
        let multilingual = selectedModel?.isMultilingual ?? false
        Picker("Language", selection: Binding(
            get: {
                guard let code = store.current.language.code?.lowercased(),
                      SpokenLanguage.whisperLanguages.contains(code) else { return "" }
                return code
            },
            set: { code in store.update { $0.language.code = code.isEmpty ? nil : code } }
        )) {
            Text("Automatic").tag("")
            Divider()
            ForEach(Self.languages, id: \.code) { language in
                Text(language.name).tag(language.code)
            }
        }
        .disabled(!multilingual)

        if !multilingual, let model = selectedModel {
            let only = SpokenLanguage.displayName(model.languages.first ?? "en")
            caption("\(model.displayName) hears \(only) only; choose a multilingual model to set a language.")
        } else if store.current.language.code == nil {
            caption("Detects each dictation's language, trusting the languages in your Mac's language settings.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
