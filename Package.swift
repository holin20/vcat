// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoCombiner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VideoCombinerApp", targets: ["VideoCombinerApp"])
    ],
    targets: [
        .executableTarget(
            name: "VideoCombinerApp",
            path: "Sources/VideoCombinerApp"
        )
    ]
)
