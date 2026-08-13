import SwiftUI
import TranscribeKit

/// Library of saved transcriptions plus the two entry points:
/// record with the microphone, or import an audio/video file.
struct HomeView: View {
    @StateObject private var store = TranscriptStore()
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @ObservedObject private var bergetCatalog = BergetModelCatalog.shared
    @AppStorage("iosLanguage") private var language = "sv"
    @AppStorage("iosDiarize") private var diarize = true
    @AppStorage("selectedTranscriptionModel") private var selectedModel = "kb_whisper-small-coreml"
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var job: AudioJob?
    @State private var importError: String?

    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private static let buildNumber =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    private var shortLanguageLabel: String {
        switch language {
        case "sv": return localized("ios_lang_short_sv")
        case "no": return localized("ios_lang_short_no")
        case "en": return localized("ios_lang_short_en")
        default: return localized("ios_lang_short_auto")
        }
    }

    /// Only models that can actually run right now: downloaded local models
    /// plus cloud models when a Berget key is configured.
    private var availableModels: [String] {
        let local = (ModelManager.kbModels + ModelManager.nbModels)
            .filter { modelManager.isModelDownloaded($0) }
        let hasKey = !(KeychainHelper.get("bergetAPIKey") ?? "").isEmpty
        let cloud = hasKey ? bergetCatalog.asrModels.map { "berget:\($0.id)" } : []
        return local + cloud
    }

    /// Compact name for the options bar: "KB Whisper Small" → "KB Small".
    private func shortModelName(_ id: String) -> String {
        modelManager.displayName(for: id)
            .replacingOccurrences(of: "Whisper ", with: "")
            .replacingOccurrences(of: " (Berget)", with: "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                if store.records.isEmpty {
                    ContentUnavailableView(
                        localized("ios_empty_title"),
                        systemImage: "waveform",
                        description: Text(localized("ios_empty_description"))
                    )
                } else {
                    List {
                        ForEach(store.records) { record in
                            NavigationLink(value: record.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title)
                                        .foregroundColor(.textPrimary)
                                        .lineLimit(1)
                                    HStack {
                                        Text(record.date, style: .date)
                                        Text(timeString(record.duration))
                                        if record.turns != nil {
                                            Image(systemName: "person.2")
                                                .font(.caption2)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                                }
                            }
                            .listRowBackground(Color.cardBackground)
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                store.delete(store.records[offset])
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    // Pull the list up under the subheading — the default
                    // scroll content inset leaves them looking disconnected
                    .contentMargins(.top, 6, for: .scrollContent)
                }
            }
            .background(Color.surfaceBackground)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ModelsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let record = store.records.first(where: { $0.id == id }) {
                    TranscriptDetailView(record: record, store: store)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    // Per-transcription options live here, not in settings —
                    // model, language, and speakers visible at the moment of
                    // choice. Only runnable models (downloaded or cloud with
                    // a key) are listed.
                    HStack(spacing: 12) {
                        Menu {
                            Picker(localized("ios_models"), selection: $selectedModel) {
                                ForEach(availableModels, id: \.self) { id in
                                    Label(modelManager.displayName(for: id),
                                          systemImage: id.hasPrefix("berget:") ? "cloud" : "cpu")
                                        .tag(id)
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selectedModel.hasPrefix("berget:") ? "cloud" : "cpu")
                                Text(shortModelName(selectedModel))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .font(.subheadline)
                        }

                        Spacer(minLength: 4)

                        Menu {
                            Picker(localized("language"), selection: $language) {
                                Text(localized("language_swedish")).tag("sv")
                                Text(localized("language_norwegian")).tag("no")
                                Text(localized("language_english")).tag("en")
                                Text(localized("ios_language_auto")).tag("auto")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                Text(shortLanguageLabel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .font(.subheadline)
                        }

                        // Speaker identification: filled green when on
                        Button {
                            diarize.toggle()
                        } label: {
                            Image(systemName: "person.2")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(diarize ? Color.primaryAccent : Color.elevatedSurface,
                                            in: Capsule())
                                .foregroundColor(diarize ? .black : .textSecondary)
                                .overlay(
                                    Capsule().strokeBorder(
                                        diarize ? Color.clear : Color.borderLight, lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.borderLight, lineWidth: 0.5)
                    )

                    HStack(spacing: 16) {
                        Button {
                            showRecorder = true
                        } label: {
                            Label(localized("ios_record"), systemImage: "mic.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button {
                            showImporter = true
                        } label: {
                            Label(localized("ios_import"), systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    // Match the options card above: same corner radius, and
                    // no capsule ends visually poking past the card's edges
                    .buttonBorderShape(.roundedRectangle(radius: 12))

                    Text(String(format: localized("ios_version"), Self.appVersion, Self.buildNumber))
                        .font(.caption2)
                        .foregroundColor(.textTertiary)
                }
                .padding()
                .background(.bar)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordView { url in
                    job = AudioJob(url: url, title: url.deletingPathExtension().lastPathComponent)
                }
            }
            .fullScreenCover(item: $job) { job in
                TranscribeRunView(job: job, store: store)
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.audio, .movie]) { result in
                if case .success(let url) = result {
                    importFile(url)
                }
            }
            .alert(localized("ios_import_failed"),
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .task {
                // Load the selected model into ANE memory in the background
                // (same as the Mac's launch prewarm) so the first
                // transcription doesn't pay the ~30s load wait.
                WhisperKitService.shared.prewarmSelectedModel()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Text(localized("ios_app_title"))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.textPrimary)

            LogoMark()

            if !store.records.isEmpty {
                Text(localized("ios_latest_transcriptions"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private struct LogoMark: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            ZStack {
                Circle()
                    .fill(LinearGradient.accentGradient)
                    .frame(width: 92, height: 92)
                Image(systemName: "mic.fill")
                    .font(.system(size: 42, weight: .medium))
                    // Matches the app icon in dark mode; white keeps the
                    // contrast on the green in light mode
                    .foregroundColor(scheme == .dark ? .black : .white)
            }
            .shadow(color: Color.primaryAccent.opacity(0.35), radius: 16, y: 4)
        }
    }

    /// Copies the picked file into Documents/Recordings — the security-scoped
    /// URL from the picker doesn't outlive the picker, and the library keeps
    /// its audio anyway.
    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var dest = RecordingService.recordingsDirectory()
            .appendingPathComponent(url.lastPathComponent)
        // Avoid clobbering an existing recording with the same name
        if FileManager.default.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            dest = RecordingService.recordingsDirectory()
                .appendingPathComponent("\(base)-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            job = AudioJob(url: dest, title: dest.deletingPathExtension().lastPathComponent)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
