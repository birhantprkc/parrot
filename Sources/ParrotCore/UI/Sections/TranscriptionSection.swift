import SwiftUI

/// The model and the spoken language (#43).
struct TranscriptionSection: View {
    @ObservedObject var store: SettingsStore
    /// A model loading behind the one in use, after a change here.
    @ObservedObject private var loading = ModelLoadStatus.shared

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
                    Text(label(model)).tag(model.id)
                }
            }

            if let state = loading.current {
                HStack(spacing: 6) {
                    switch state.phase {
                    case .downloading(let fraction?):
                        ProgressView(value: fraction).frame(width: 80)
                    case .downloading(nil), .loading:
                        ProgressView().controlSize(.small)
                    case .failed:
                        EmptyView()
                    }
                    caption(Self.capitalized(state.text))
                }
            }

            languagePicker
        }
    }

    /// "Whisper Large v3 Turbo · 1620 MB · downloaded". Read when the picker
    /// draws, so a finished download shows the next time it opens. The model
    /// folder appears as soon as a download starts, so the one downloading
    /// says so instead.
    private func label(_ model: TranscriptionModel) -> String {
        var label = "\(model.displayName) · \(model.sizeMB) MB"
        if let state = loading.current, state.modelID == model.id, case .downloading = state.phase {
            label += " · downloading"
        } else if WhisperKitTranscriber.isCached(model) {
            label += " · downloaded"
        }
        return label
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
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
