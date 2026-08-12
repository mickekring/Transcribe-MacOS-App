import SwiftUI
import TranscribeKit

@main
struct TranscribeiOSApp: App {
    // Same key and dark-default as the Mac app
    @AppStorage("appColorScheme") private var appColorScheme = "dark"

    init() {
        // Same lesson as the Mac app: iOS purges app Caches under storage
        // pressure, which would throw away the multi-minute ANE model
        // specialization. Must run before the first model load.
        ANECacheProtector.protect()

        Self.excludeLocalDataFromBackup()
    }

    /// Privacy: nothing recorded or transcribed leaves the phone. The app's
    /// Documents and Application Support folders are included in iCloud/
    /// computer backups by default — exclude them so recordings and
    /// transcripts stay strictly on-device. Models and the ANE cache are
    /// excluded too (multi-GB and re-downloadable/rebuildable; Apple's
    /// guidelines want those out of backups regardless).
    private static func excludeLocalDataFromBackup() {
        let fm = FileManager.default
        var targets = [
            RecordingService.recordingsDirectory(),
            TranscriptStore.directory
        ]
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let bundleId = Bundle.main.bundleIdentifier {
            targets.append(appSupport.appendingPathComponent(bundleId))
        }
        // MLX/swift-transformers downloads LLM weights under Documents/huggingface
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            targets.append(documents.appendingPathComponent("huggingface"))
        }
        for target in targets {
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            var url = target
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(.primaryAccent)
                .preferredColorScheme(AppTheme(rawValue: appColorScheme)?.colorScheme)
        }
    }
}
