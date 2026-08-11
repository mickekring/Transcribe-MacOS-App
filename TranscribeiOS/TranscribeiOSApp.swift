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
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(.primaryAccent)
                .preferredColorScheme(AppTheme(rawValue: appColorScheme)?.colorScheme)
        }
    }
}
