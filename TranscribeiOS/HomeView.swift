import SwiftUI
import TranscribeKit

/// Library of saved transcriptions plus the two entry points:
/// record with the microphone, or import an audio/video file.
struct HomeView: View {
    @StateObject private var store = TranscriptStore()
    @State private var showRecorder = false
    @State private var showImporter = false
    @State private var job: AudioJob?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "Inga transkriberingar än",
                        systemImage: "waveform",
                        description: Text("Spela in eller importera en ljudfil för att komma igång.")
                    )
                } else {
                    List {
                        ForEach(store.records) { record in
                            NavigationLink(value: record.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title)
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
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                store.delete(store.records[offset])
                            }
                        }
                    }
                }
            }
            .navigationTitle("Transcribe")
            .navigationDestination(for: UUID.self) { id in
                if let record = store.records.first(where: { $0.id == id }) {
                    TranscriptDetailView(record: record, store: store)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        ModelsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    Button {
                        showRecorder = true
                    } label: {
                        Label("Spela in", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button {
                        showImporter = true
                    } label: {
                        Label("Importera", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
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
            .alert("Kunde inte importera",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
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
