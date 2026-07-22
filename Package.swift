// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpeedOCRRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "speedocr", targets: ["SpeedOCRRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "SpeedOCRRecorder",
            path: "Sources/SpeedOCRRecorder"
        )
    ]
)
