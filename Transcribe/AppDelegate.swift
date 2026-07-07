import Cocoa
import SwiftUI
import os

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?
    private var statusBarItem: NSStatusItem?
    /// The main WindowGroup window, captured by TranscribeApp when its content appears
    weak var mainWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must run before the first model load (the launch prewarm) so
        // CoreML writes its ANE cache through the protected location.
        protectANECache()

        // Clean up any leftover files from previous session (in case of force quit)
        cleanupTemporaryFiles(isStartup: true)

        setupStatusBar()
    }

    /// Protects CoreML's ANE specialization cache from cache purges.
    ///
    /// CoreML stores compiled-for-Neural-Engine model code (minutes of build
    /// time per large model) under this sandbox's Caches directory, which
    /// macOS and cleaner utilities treat as disposable. This relocates the
    /// cache into Application Support (treated as user data) and leaves a
    /// symlink at the original path — CoreML follows it transparently. If a
    /// purge deletes the symlink, it is recreated here on next launch and the
    /// compiled models survive. Also prunes cache entries for older macOS
    /// builds, which are orphaned by OS updates (the cache is keyed by build).
    private func protectANECache() {
        let logger = Logger(subsystem: "com.mickekring.transcribe", category: "ANECache")
        let fm = FileManager.default
        guard let bundleId = Bundle.main.bundleIdentifier,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let linkURL = caches
            .appendingPathComponent(bundleId)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache")
        let homeURL = appSupport
            .appendingPathComponent(bundleId)
            .appendingPathComponent("ANECache")

        do {
            try fm.createDirectory(at: homeURL, withIntermediateDirectories: true)
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

            // Prune entries orphaned by macOS updates (keyed by OS build)
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
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanupTemporaryFiles(isStartup: false)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusBarItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribe")
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Transcribe", action: #selector(openMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "New Recording", action: #selector(startNewRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick Transcribe", action: #selector(quickTranscribe), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusBarItem?.menu = menu
    }
    
    private func cleanupTemporaryFiles(isStartup: Bool = false) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("Transcribe")
        
        do {
            try FileManager.default.removeItem(at: tempDir)
        } catch {
            // Cleanup failed or directory doesn't exist
        }
    }
    
    @objc func statusBarButtonClicked() {
        if let menu = statusBarItem?.menu {
            statusBarItem?.button?.performClick(nil)
        }
    }
    
    @objc func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the tracked main window; fall back to finding the WindowGroup
        // window by identifier (never the status bar or About windows)
        if let window = mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue.contains("AppWindow") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Main window was closed and released — ask SwiftUI to recreate the WindowGroup scene
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        }
    }

    @objc func startNewRecording() {
        // Restore the main window first so ContentView is alive to receive the notification
        openMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .startNewRecording, object: nil)
        }
    }
    
    @objc func quickTranscribe() {
        // Show quick transcribe floating window
        let quickTranscribeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        quickTranscribeWindow.isReleasedWhenClosed = false
        quickTranscribeWindow.title = "Quick Transcribe"
        quickTranscribeWindow.center()
        quickTranscribeWindow.contentView = NSHostingView(rootView: QuickTranscribeView())
        quickTranscribeWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        // Open the SwiftUI Settings scene (same window as the app menu's Settings item)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            aboutWindow?.isReleasedWhenClosed = false
            aboutWindow?.title = "About Transcribe"
            aboutWindow?.center()
            aboutWindow?.contentView = NSHostingView(rootView: AboutView())
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let startNewRecording = Notification.Name("startNewRecording")
    static let quickTranscribe = Notification.Name("quickTranscribe")
}