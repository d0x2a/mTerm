// swift-tools-version:5.10
import PackageDescription

// Three layers, split so an iOS client can reuse the terminal without the
// AppKit shell. MTermCore and MTermRender build for both platforms; MTermApp
// and the executable are macOS-only and simply aren't depended on from iOS.
//
// Cross-target symbols use `package` rather than `public`: it restores exactly
// the visibility these files had as one module, without exporting the parser's
// internals to anything outside this package.
let package = Package(
    name: "mTerm",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MTermCore", targets: ["MTermCore"]),
        .library(name: "MTermRender", targets: ["MTermRender"]),
        .library(name: "MTermApp", targets: ["MTermApp"]),
        .executable(name: "mTerm", targets: ["mTerm"])
    ],
    targets: [
        .target(
            name: "CMTermBridge",
            path: "Sources/CMTermBridge",
            publicHeadersPath: "include"
        ),
        // Parser, grid, themes, triggers, tmux control mapping, key encoding.
        // Foundation/CoreText only — no AppKit, no PTY, no window.
        .target(
            name: "MTermCore",
            path: "Sources/MTermCore"
        ),
        // Glyph atlas and the Metal cell pipeline. CAMetalLayer exists on both
        // platforms; the NSView that hosts it does not, so it stays in MTermApp.
        .target(
            name: "MTermRender",
            dependencies: ["MTermCore"],
            path: "Sources/MTermRender"
        ),
        .target(
            name: "MTermApp",
            dependencies: ["MTermCore", "MTermRender", "CMTermBridge"],
            path: "Sources/MTermApp"
        ),
        .executableTarget(
            name: "mTerm",
            dependencies: ["MTermApp"],
            path: "Sources/mTerm"
        )
    ]
)
