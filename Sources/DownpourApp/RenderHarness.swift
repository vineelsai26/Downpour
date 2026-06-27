import SwiftUI
import AppKit
import BackupCore

/// Off-screen renderer for verification: renders `ContentView` to a PNG without
/// opening a window. Invoked via `--render-ui <out.png> [sampleDestPath]`.
enum RenderHarness {
    @MainActor
    static func run() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--render-ui"), idx + 1 < args.count else {
            FileHandle.standardError.write(Data("usage: --render-ui <out.png> [destPath]\n".utf8))
            exit(2)
        }
        let outPath = args[idx + 1]

        let controller = BackupController()
        if idx + 2 < args.count, !args[idx + 2].hasPrefix("--") {
            controller.destinationPath = args[idx + 2]
        }
        if args.contains("--demo") {
            controller.applyDemoRunningState()
        }

        let view = BackupBody()
            .environmentObject(controller)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outPath))
            print("rendered \(outPath)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
