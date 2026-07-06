import SwiftUI

@main
struct TranscribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
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
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(transcriptionManager)
                .environmentObject(settingsManager)
                .frame(minWidth: 900, minHeight: 700)
                .frame(idealWidth: 1200, idealHeight: 850)
                .preferredColorScheme(preferredScheme)
                .background(WindowAccessor { window in
                    appDelegate.mainWindow = window
                    // Persist window size/position across launches
                    if window.frameAutosaveName != "TranscribeMainWindow" {
                        window.setFrameAutosaveName("TranscribeMainWindow")
                    }
                })
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Transcribe") {
                    appDelegate.showAboutWindow()
                }
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
