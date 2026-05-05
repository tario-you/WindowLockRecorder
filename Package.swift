// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WindowLockRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WindowLockRecorder", targets: ["WindowLockRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "WindowLockRecorder",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
