import SwiftUI
import TranscribeKit

/// Displays a saved transcript: plain text or speaker-labeled view,
/// speaker renaming, and share-sheet export.
struct TranscriptDetailView: View {
    @State var record: TranscriptRecord
    @ObservedObject var store: TranscriptStore

    @State private var showSpeakers = false
    @State private var renamingSpeaker: Int?
    @State private var newName = ""

    private var displayedText: String {
        if showSpeakers, let speakerText = record.speakerTranscript {
            return speakerText
        }
        return record.text
    }

    var body: some View {
        ScrollView {
            Text(displayedText)
                .font(.callout)
                .foregroundColor(.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color.surfaceBackground)
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if record.speakerTranscript != nil {
                Picker("Visning", selection: $showSpeakers) {
                    Text("Text").tag(false)
                    Text("Talare").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if showSpeakers && !record.speakerIds.isEmpty {
                    Menu {
                        ForEach(record.speakerIds, id: \.self) { id in
                            Button(speakerLabel(id)) {
                                newName = record.speakerNames[id] ?? ""
                                renamingSpeaker = id
                            }
                        }
                    } label: {
                        Image(systemName: "person.2")
                    }
                }
                ShareLink(item: displayedText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .alert("Byt namn på \(renamingSpeaker.map(speakerLabel) ?? "")",
               isPresented: Binding(get: { renamingSpeaker != nil },
                                    set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("Namn", text: $newName)
            Button("Spara") {
                if let id = renamingSpeaker {
                    record.speakerNames[id] = newName.trimmingCharacters(in: .whitespaces)
                    if record.speakerNames[id]?.isEmpty == true {
                        record.speakerNames.removeValue(forKey: id)
                    }
                    store.update(record)
                }
                renamingSpeaker = nil
            }
            Button("Avbryt", role: .cancel) { renamingSpeaker = nil }
        }
    }

    private func speakerLabel(_ id: Int) -> String {
        record.speakerNames[id] ?? String(format: localized("speaker_label"), id + 1)
    }
}
