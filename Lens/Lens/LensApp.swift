import SwiftUI

@main
struct LensApp: App {
    @StateObject private var state = ScanState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(nil) // honor system appearance
        }
    }
}
