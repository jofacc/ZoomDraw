// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZoomDraw",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZoomDraw", targets: ["ZoomDraw"])
    ],
    targets: [
        .executableTarget(
            name: "ZoomDraw",
            path: "Sources/ZoomDraw"
        )
    ]
)
