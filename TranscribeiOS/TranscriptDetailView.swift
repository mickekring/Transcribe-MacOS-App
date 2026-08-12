import SwiftUI
import TranscribeKit

/// Displays a saved transcript: plain text or speaker-labeled view,
/// speaker renaming, title renaming, and share-sheet export of the
/// text or the original audio file.
struct TranscriptDetailView: View {
    @State var record: TranscriptRecord
    @ObservedObject var store: TranscriptStore
    @ObservedObject private var localization = LocalizationManager.shared

    @State private var showSpeakers = false
    @State private var renamingSpeaker: Int?
    @State private var newName = ""
    @State private var renamingTitle = false
    @State private var newTitle = ""
    @State private var showSummarize = false

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
                Picker("", selection: $showSpeakers) {
                    Text(localized("ios_text_tab")).tag(false)
                    Text(localized("ios_speakers")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSummarize = true
                } label: {
                    Label(localized("ios_summarize"), systemImage: "sparkles")
                }

                Menu {
                    Button {
                        newTitle = record.title
                        renamingTitle = true
                    } label: {
                        Label(localized("ios_rename_transcription"), systemImage: "pencil")
                    }
                    if showSpeakers && !record.speakerIds.isEmpty {
                        Menu {
                            ForEach(record.speakerIds, id: \.self) { id in
                                Button(speakerLabel(id)) {
                                    newName = record.speakerNames[id] ?? ""
                                    renamingSpeaker = id
                                }
                            }
                        } label: {
                            Label(localized("ios_rename_speakers"), systemImage: "person.2")
                        }
                    }
                } label: {
                    Label(localized("ios_rename"), systemImage: "pencil")
                }

                Menu {
                    ShareLink(item: displayedText) {
                        Label(localized("ios_share_text"), systemImage: "doc.text")
                    }
                    if let audio = record.audioURL {
                        ShareLink(item: audio) {
                            Label(localized("ios_share_audio"), systemImage: "waveform")
                        }
                    }
                } label: {
                    Label(localized("save_copy"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showSummarize) {
            SummarizeView(transcriptText: displayedText)
        }
        .alert(String(format: localized("ios_rename_speaker_title"),
                      renamingSpeaker.map(speakerLabel) ?? ""),
               isPresented: Binding(get: { renamingSpeaker != nil },
                                    set: { if !$0 { renamingSpeaker = nil } })) {
            TextField(localized("ios_name"), text: $newName)
            Button(localized("save")) {
                if let id = renamingSpeaker {
                    record.speakerNames[id] = newName.trimmingCharacters(in: .whitespaces)
                    if record.speakerNames[id]?.isEmpty == true {
                        record.speakerNames.removeValue(forKey: id)
                    }
                    store.update(record)
                }
                renamingSpeaker = nil
            }
            Button(localized("cancel"), role: .cancel) { renamingSpeaker = nil }
        }
        .alert(localized("ios_rename_transcription"), isPresented: $renamingTitle) {
            TextField(localized("ios_name"), text: $newTitle)
            Button(localized("save")) {
                let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    record.title = trimmed
                    store.update(record)
                }
                renamingTitle = false
            }
            Button(localized("cancel"), role: .cancel) { renamingTitle = false }
        }
    }

    private func speakerLabel(_ id: Int) -> String {
        record.speakerNames[id] ?? String(format: localized("speaker_label"), id + 1)
    }
}
