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
                .onAppear {
                    appDelegate.settingsManager = settingsManager
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Transcribe") {
                    appDelegate.showAboutWindow()
                }
            }
            
            CommandGroup(after: .appSettings) {
                Button("Preferences...") {
                    appDelegate.showPreferences()
                }
                .keyboardShortcut(",", modifiers: .command)
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
