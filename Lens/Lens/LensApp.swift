import SwiftUI

@main
struct LensApp: App {
    @StateObject private var state = ScanState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(nil) // honor system appearance
                .task { applyUITestHooks() }
        }
    }

    /// UI-test hook: when launched with `-uiTestPreloadFixturePath` followed by
    /// an absolute host file path (Mac filesystem is mounted into the iOS
    /// simulator), populate the scan state with that image so the test can land
    /// directly on the Review screen. No-op in production.
    @MainActor
    private func applyUITestHooks() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiTestPreloadFixturePath"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return }
        state.add(images: [image], defaultFilter: .bw)
    }
}
