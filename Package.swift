// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StickSVG",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "StickSVG", targets: ["StickSVG"])],
    targets: [
        .target(name: "VectorEngine", path: "Sources/VectorEngine"),
        .executableTarget(name: "StickSVG", dependencies: ["VectorEngine"], path: "Sources/StickSVG"),
        .testTarget(name: "VectorEngineTests", dependencies: ["VectorEngine"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)

