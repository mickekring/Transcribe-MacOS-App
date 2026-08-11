import Cocoa
import TranscribeKit
import SwiftUI
import os

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?
    private var statusBarItem: NSStatusItem?
    /// The main WindowGroup window, captured by TranscribeApp when its content appears
    weak var mainWindow: NSWindow?
    private var frameObservers: [Any] = []

    /// Explicit window-frame persistence. AppKit's frameAutosaveName is
    /// unreliable under SwiftUI window management (frames were never saved),
    /// so the frame is stored in UserDefaults on resize/move/close and
    /// restored when the window is first captured.
    func adoptMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window

        let key = "MainWindowFrame"
        if let saved = UserDefaults.standard.string(forKey: key) {
            let frame = NSRectFromString(saved)
            if frame.width > 0, frame.height > 0 {
                window.setFrame(frame, display: true)
            }
        }

        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameObservers = [
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.willCloseNotification
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                guard let w = note.object as? NSWindow else { return }
                UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: key)
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must run before the first model load (the launch prewarm) so
        // CoreML writes its ANE cache through the protected location.
        ANECacheProtector.protect()

        // Clean up any leftover files from previous session (in case of force quit)
        cleanupTemporaryFiles(isStartup: true)

        setupStatusBar()
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