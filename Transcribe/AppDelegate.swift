import Cocoa
import TranscribeKit
import SwiftUI
import os

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// The app's delegate. With SwiftUI's delegate adaptor `NSApp.delegate`
    /// is SwiftUI's own object, not this one.
    private(set) static weak var shared: AppDelegate?

    override init() {
        super.init()
        Self.shared = self
    }

    private var aboutWindow: NSWindow?
    private var quickTranscribeWindow: NSWindow?
    private var statusBarItem: NSStatusItem?
    /// The main window, captured by TranscribeApp when its content appears
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
            // Only restore a frame that is still reachable: after an external
            // display is unplugged the saved position can be off every screen.
            let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 120 && $0.visibleFrame.intersection(frame).height >= 80 }
            if frame.width > 0, frame.height > 0, isVisible {
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
        cleanupTemporaryFiles()

        setupStatusBar()
    }

    /// Quitting discards temp files, so ask before throwing away a recording
    /// or transcript that exists nowhere else.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard let unsaved = state.unsavedWork ?? (state.quickTranscriptUnsaved ? .unsavedTranscript : nil) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch unsaved {
        case .recordingInProgress:
            alert.messageText = localized("quit_recording_title")
            alert.informativeText = localized("quit_recording_message")
        case .untranscribedRecording:
            alert.messageText = localized("quit_untranscribed_title")
            alert.informativeText = localized("quit_untranscribed_message")
        case .unsavedTranscript:
            alert.messageText = localized("quit_unsaved_transcript_title")
            alert.informativeText = localized("quit_unsaved_transcript_message")
        }
        alert.addButton(withTitle: localized("stay"))
        alert.addButton(withTitle: localized("quit_anyway"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupTemporaryFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribe")

        let menu = NSMenu()
        menu.delegate = self
        statusBarItem?.menu = menu
        populate(menu)
    }

    /// Rebuilt each time it opens so it follows the in-app language setting.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ titleKey: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: localized(titleKey), action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        add("menu_open_app", #selector(openMainWindow))
        menu.addItem(.separator())
        add("new_recording", #selector(startNewRecording))
        add("menu_quick_transcribe", #selector(quickTranscribe))
        menu.addItem(.separator())
        add("menu_settings", #selector(showPreferences), key: ",")
        add("help_title", #selector(showHelp))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("menu_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Another copy of the app (same bundle id, so the same sandbox container
    /// and temp folder) is running — e.g. the installed app next to a debug
    /// build. Its recordings live in the folder this instance would wipe.
    private var anotherInstanceIsRunning: Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
    }

    private func cleanupTemporaryFiles() {
        // The temp folder is shared by every running copy; whichever copy
        // quits last (or starts alone) does the cleanup.
        guard !anotherInstanceIsRunning else { return }
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("Transcribe")
        try? fm.removeItem(at: tempDir)
        // FluidAudio decodes long files to raw audio in the top-level temp
        // folder and leaves the file behind when a conversion fails
        let leftovers = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in leftovers where file.lastPathComponent.hasPrefix("fluidaudio-") {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Actions

    @objc func openMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The window was closed and released: ask SwiftUI for the scene again
            SceneActions.shared.openMainWindow?()
        }
    }

    @objc func startNewRecording() {
        openMainWindow()
        // After the window exists; asks first if another screen holds unsaved work
        DispatchQueue.main.async {
            AppState.shared.navigate(to: .recording)
        }
    }

    func requestOpenFile() {
        openMainWindow()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .requestOpenFile, object: nil)
        }
    }

    @objc func quickTranscribe() {
        NSApp.activate()
        if quickTranscribeWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = localized("menu_quick_transcribe")
            window.center()
            window.contentView = NSHostingView(rootView: QuickTranscribeView())
            quickTranscribeWindow = window
        }
        quickTranscribeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showPreferences() {
        NSApp.activate()
        SceneActions.shared.openSettings?()
    }

    @objc func showHelp() {
        NSApp.activate()
        SceneActions.shared.openHelp?()
    }

    func showAboutWindow() {
        if aboutWindow == nil {
            aboutWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 556),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            aboutWindow?.isReleasedWhenClosed = false
            aboutWindow?.title = localized("menu_about")
            aboutWindow?.center()
            aboutWindow?.contentView = NSHostingView(rootView: AboutView())
        }
        NSApp.activate()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let requestOpenFile = Notification.Name("requestOpenFile")
}
