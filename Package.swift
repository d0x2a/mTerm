// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mTerm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CMTermBridge",
            path: "Sources/CMTermBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "mTerm",
            dependencies: ["CMTermBridge"],
            path: "Sources/mTerm"
        )
    ]
)
