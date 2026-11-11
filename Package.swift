// swift-tools-version: 6.0
import PackageDescription

// Zero third-party dependencies: SQLite comes from the system SDK and
// everything else is Foundation / AppKit / SwiftUI / Carbon.
//
// Layering is deliberate: PasteCore (storage) and PasteAgent (pure business
// rules) are unit tested; PasteApp holds the AppKit / Carbon integration that
// can only be verified on a real Mac. `paste-dbcheck` is a read-only
// diagnostic for the app's database.
let package = Package(
    name: "Paste",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PasteCore", targets: ["PasteCore"]),
        .library(name: "PasteAgent", targets: ["PasteAgent"]),
        .executable(name: "PasteApp", targets: ["PasteApp"]),
        .executable(name: "paste-dbcheck", targets: ["PasteDiagnostics"]),
    ],
    targets: [
        .target(name: "PasteCore"),
        .target(name: "PasteAgent", dependencies: ["PasteCore"]),
        .executableTarget(
            name: "PasteApp",
            dependencies: ["PasteCore", "PasteAgent"]
        ),
        .executableTarget(name: "PasteDiagnostics", dependencies: ["PasteCore"]),
        .testTarget(name: "PasteCoreTests", dependencies: ["PasteCore"]),
        .testTarget(name: "PasteAgentTests", dependencies: ["PasteAgent", "PasteCore"]),
    ]
)
