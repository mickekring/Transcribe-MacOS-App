import SwiftUI
import TranscribeKit

@main
struct TranscribeiOSApp: App {
    init() {
        // Same lesson as the Mac app: iOS purges app Caches under storage
        // pressure, which would throw away the multi-minute ANE model
        // specialization. Must run before the first model load.
        ANECacheProtector.protect()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
