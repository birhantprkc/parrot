import SwiftUI

/// The model and the spoken language (#43).
struct TranscriptionSection: View {
    @ObservedObject var store: SettingsStore

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
        }
    }
}
