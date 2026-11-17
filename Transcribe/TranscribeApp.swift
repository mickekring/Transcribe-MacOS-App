import SwiftUI
import TranscribeKit

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var settingsManager = SettingsManager()
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        // A single-instance window: the app has one recorder, one loaded
        // model and one navigation state, so a second window (⌘N) would
        // mirror the first and run the same work twice.
        Window("Transcribe", id: SceneID.main) {
            ContentView()
                .environmentObject(appState)
                .environmentObject(transcriptionManager)
                .environmentObject(settingsManager)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(preferredScheme)
                .background(WindowAccessor { window in
                    // Captures the window for status-bar restore and
                    // saves/restores its frame across launches
                    appDelegate.adoptMainWindow(window)
                })
        }
        // 16:9 default that fits every supported Mac's screen; the frame
        // autosave takes over once the user resizes.
        .defaultSize(width: 1280, height: 720)
        // Always open the window at launch. A single-window scene otherwise
        // restores "closed" if the window was closed (or never shown) when
        // the app last quit, leaving only the status-bar icon.
        .defaultLaunchBehavior(.presented)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(localized("menu_about")) {
                    appDelegate.showAboutWindow()
                }
            }
            CommandGroup(after: .newItem) {
                Button(localized("open_files")) {
                    appDelegate.requestOpenFile()
                }
                .keyboardShortcut("o")
                Button(localized("new_recording")) {
                    appDelegate.startNewRecording()
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settingsManager)
                .navigationTitle("")
                .preferredColorScheme(preferredScheme)
        }
    }
}

enum SceneID {
    static let main = "main"
}

/// Scene actions captured from the SwiftUI environment so AppKit code (the
/// status-bar menu) can reopen the main window or show Settings even after
/// the window, and the view that captured them, are gone.
@MainActor
final class SceneActions {
    static let shared = SceneActions()
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    private init() {}
}

/// Captures the hosting NSWindow so AppDelegate can restore the main window
/// from the status bar menu.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
