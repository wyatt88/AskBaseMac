// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AskBaseMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AskBaseCore", targets: ["AskBaseCore"]),
        .executable(name: "AskBaseMac", targets: ["AskBaseMac"]),
        .executable(name: "askbase", targets: ["AskBaseCLI"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AskBaseCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "AskBaseMac", dependencies: ["AskBaseCore"]),
        .executableTarget(name: "AskBaseCLI", dependencies: ["AskBaseCore"]),
        .testTarget(name: "AskBaseCoreTests", dependencies: ["AskBaseCore"]),
    ],
    swiftLanguageModes: [.v5]
)
