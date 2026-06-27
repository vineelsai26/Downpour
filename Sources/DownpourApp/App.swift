import SwiftUI

struct DownpourApp: App {
    @StateObject private var controller = BackupController()

    var body: some Scene {
        WindowGroup("Downpour") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 620, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Entry point. Supports a hidden `--render-ui <out.png> [sampleDestPath]` mode
/// that renders the UI off-screen to a PNG (used for verification) instead of
/// launching the windowed app.
@main
enum AppMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--render-ui") {
            RenderHarness.run()
        } else if args.contains("--backup") {
            HeadlessBackup.run()
        } else {
            DownpourApp.main()
        }
    }
}
