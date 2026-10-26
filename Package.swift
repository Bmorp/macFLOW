// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Atoll",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Atoll",
            path: "Sources/Atoll",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Quartz"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedLibrary("sqlite3"),
                // The on-device model exists from macOS 26; weak-linked so Atoll still launches on 14 and 15.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .testTarget(
            name: "AtollTests",
            dependencies: ["Atoll"],
            path: "Tests/AtollTests"
        ),
    ]
)
