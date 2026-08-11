import Foundation
import os

/// Protects CoreML's ANE specialization cache from cache purges.
///
/// CoreML stores compiled-for-Neural-Engine model code (minutes of build
/// time per large model) under the app's Caches directory, which the OS
/// (and, on macOS, cleaner utilities) treats as disposable. This relocates
/// the cache into Application Support (treated as user data) and leaves a
/// symlink at the original path — CoreML follows it transparently. If a
/// purge deletes the symlink, it is recreated here on next launch and the
/// compiled models survive. Also prunes cache entries for older OS builds,
/// which are orphaned by OS updates (the cache is keyed by build).
///
/// Call once at app launch, before the first model load, on both platforms.
public enum ANECacheProtector {

    public static func protect() {
        let logger = Logger(subsystem: "com.mickekring.transcribe", category: "ANECache")
        let fm = FileManager.default
        guard let bundleId = Bundle.main.bundleIdentifier,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let cacheName = "com.apple.e5rt.e5bundlecache"
        let homeURL = appSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent("ANECache")

        // macOS puts the e5rt cache under Caches/<bundleId>/; the iOS sandbox
        // Caches directory is already app-scoped, so cover both layouts there.
        // Protecting a path CoreML never uses just leaves an unused symlink.
        #if os(macOS)
        let linkURLs = [caches.appendingPathComponent(bundleId).appendingPathComponent(cacheName)]
        #else
        let linkURLs = [
            caches.appendingPathComponent(cacheName),
            caches.appendingPathComponent(bundleId).appendingPathComponent(cacheName)
        ]
        #endif

        do {
            try fm.createDirectory(at: homeURL, withIntermediateDirectories: true)

            for linkURL in linkURLs {
                try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let linkPath = linkURL.path
                var isDirectory: ObjCBool = false
                let attributes = try? fm.attributesOfItem(atPath: linkPath)
                let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

                if isSymlink {
                    // Recreate if broken or pointing elsewhere
                    let target = try? fm.destinationOfSymbolicLink(atPath: linkPath)
                    if target != homeURL.path {
                        try fm.removeItem(at: linkURL)
                        try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
                        logger.info("Recreated ANE cache symlink")
                    }
                } else if fm.fileExists(atPath: linkPath, isDirectory: &isDirectory), isDirectory.boolValue {
                    // Real cache directory from before this protection existed:
                    // merge its contents into the protected home, then replace
                    // the directory with the symlink.
                    for buildDir in try fm.contentsOfDirectory(at: linkURL, includingPropertiesForKeys: nil) {
                        let destBuild = homeURL.appendingPathComponent(buildDir.lastPathComponent)
                        if !fm.fileExists(atPath: destBuild.path) {
                            try fm.moveItem(at: buildDir, to: destBuild)
                        } else {
                            for entry in try fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil) {
                                let destEntry = destBuild.appendingPathComponent(entry.lastPathComponent)
                                if !fm.fileExists(atPath: destEntry.path) {
                                    try fm.moveItem(at: entry, to: destEntry)
                                }
                            }
                        }
                    }
                    try fm.removeItem(at: linkURL)
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
                    logger.info("Migrated ANE cache to Application Support and linked it")
                } else {
                    // Nothing at the cache path yet (fresh install or purged)
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: homeURL)
                    logger.info("Created ANE cache symlink")
                }
            }

            // Prune entries orphaned by OS updates (keyed by OS build)
            var osVersionSize = 0
            sysctlbyname("kern.osversion", nil, &osVersionSize, nil, 0)
            var osVersionChars = [CChar](repeating: 0, count: osVersionSize)
            sysctlbyname("kern.osversion", &osVersionChars, &osVersionSize, nil, 0)
            let currentBuild = String(cString: osVersionChars)
            if !currentBuild.isEmpty {
                for buildDir in (try? fm.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: nil)) ?? [] {
                    if buildDir.lastPathComponent != currentBuild {
                        try? fm.removeItem(at: buildDir)
                        logger.info("Pruned stale ANE cache for OS build \(buildDir.lastPathComponent, privacy: .public)")
                    }
                }
            }
        } catch {
            // Best effort: on any failure CoreML just uses the default path
            // and behavior is the pre-protection status quo.
            logger.error("ANE cache protection failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
