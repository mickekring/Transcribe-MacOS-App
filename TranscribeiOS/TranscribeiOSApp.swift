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

        Self.protectHubCache()
        Self.excludeLocalDataFromBackup()
    }

    /// The HuggingFace hub client stores LLM weights under
    /// Library/Caches/huggingface — purgeable, meaning iOS could evict
    /// gigabytes of model weights under storage pressure. Relocate to
    /// Application Support (backup-excluded below) behind a symlink,
    /// exactly like the ANE cache protection.
    private static func protectHubCache() {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let bundleId = Bundle.main.bundleIdentifier else { return }

        let linkURL = caches.appendingPathComponent("huggingface")
        let homeURL = appSupport.appendingPathComponent(bundleId).appendingPathComponent("HuggingFaceLLM")

        do {
            try fm.createDirectory(at: homeURL, withIntermediateDirectories: true)
            let attributes = try? fm.attributesOfItem(atPath: linkURL.path)
            let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

            if isSymlink {
                if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != homeURL.path {
                    try fm.removeItem(at: linkURL)
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
                }
            } else if fm.fileExists(atPath: linkURL.path) {
                // Real directory from before protection: merge and replace
                for entry in try fm.contentsOfDirectory(at: linkURL, includingPropertiesForKeys: nil) {
                    let dest = homeURL.appendingPathComponent(entry.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try fm.moveItem(at: entry, to: dest)
                    }
                }
                try fm.removeItem(at: linkURL)
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
            } else {
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
            }
        } catch {
            // Best effort — without protection the client just uses Caches
        }
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
