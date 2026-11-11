import AppKit
import Foundation

let arguments = CommandLine.arguments
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Paste — macOS clipboard history

    Usage: Paste [--help] [--self-check]

      --help        Show this message and exit
      --self-check  Verify the data directory, database, settings and icon
    """)
    exit(0)
}
if arguments.contains("--self-check") {
    SelfCheck.run()
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

do {
    let controller = try AppController()
    controller.start()
    // Keep the controller alive for the whole run loop.
    withExtendedLifetime(controller) {
        application.run()
    }
} catch {
    FileHandle.standardError.write(Data("[paste] startup failed: \(error)\n".utf8))
    exit(1)
}
