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
    @State private var showInfo = false
    @AppStorage("iosLLMEnabled") private var llmEnabled = true

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
                    showInfo = true
                } label: {
                    Label(localized("ios_info"), systemImage: "info.circle")
                }

                if llmEnabled {
                    Button {
                        showSummarize = true
                    } label: {
                        Label(localized("ios_summarize"), systemImage: "sparkles")
                    }
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
            SummarizeView(record: record, store: store)
        }
        .sheet(isPresented: $showInfo) {
            RecordInfoView(record: record)
                .presentationDetents([.medium, .large])
        }
        .alert(String(format: localized("ios_rename_speaker_title"),
                      renamingSpeaker.map(speakerLabel) ?? ""),
               isPresented: Binding(get: { renamingSpeaker != nil },
                                    set: { if !$0 { renamingSpeaker = nil } })) {
            TextField(localized("ios_name"), text: $newName)
            Button(localized("save")) {
                if let id = renamingSpeaker {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    if let updated = store.modify(record.id, { rec in
                        if trimmed.isEmpty {
                            rec.speakerNames.removeValue(forKey: id)
                        } else {
                            rec.speakerNames[id] = trimmed
                        }
                    }) {
                        record = updated
                    }
                }
                renamingSpeaker = nil
            }
            Button(localized("cancel"), role: .cancel) { renamingSpeaker = nil }
        }
        .alert(localized("ios_rename_transcription"), isPresented: $renamingTitle) {
            TextField(localized("ios_name"), text: $newTitle)
            Button(localized("save")) {
                let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty,
                   let updated = store.modify(record.id, { $0.title = trimmed }) {
                    record = updated
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

/// Metadata sheet: what produced this transcription and how fast.
struct RecordInfoView: View {
    let record: TranscriptRecord
    @ObservedObject private var localization = LocalizationManager.shared

    var body: some View {
        NavigationStack {
            List {
                LabeledContent(localized("ios_info_date"),
                               value: record.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(localized("ios_info_duration"), value: timeString(record.duration))
                LabeledContent(localized("ios_info_model"),
                               value: ModelManager.shared.displayName(for: record.modelId))
                if let language = record.language {
                    LabeledContent(localized("ios_info_language"), value: languageName(language))
                }
                if let seconds = record.transcriptionSeconds, seconds > 0 {
                    LabeledContent(localized("ios_info_transcription_time"), value: timeString(seconds))
                    if record.duration > 0 {
                        LabeledContent(localized("ios_info_realtime"),
                                       value: String(format: "%.1f×", record.duration / seconds))
                    }
                }
                if record.turns != nil {
                    LabeledContent(localized("ios_info_speakers"), value: "\(record.speakerIds.count)")
                }
                if let audioURL = record.audioURL,
                   let bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.size] as? Int64 {
                    LabeledContent(localized("ios_info_audio_file"),
                                   value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.surfaceBackground)
            .navigationTitle(localized("ios_info"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func languageName(_ code: String) -> String {
        switch code {
        case "sv": return localized("language_swedish")
        case "no": return localized("language_norwegian")
        case "en": return localized("language_english")
        default: return localized("ios_language_auto")
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        if s >= 60 { return String(format: "%d min %d s", s / 60, s % 60) }
        return String(format: "%d s", s)
    }
}
