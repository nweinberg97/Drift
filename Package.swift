// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Drift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Drift", targets: ["Drift"]),
        .library(name: "DriftCore", targets: ["DriftCore"]),
    ],
    targets: [
        // Pure, platform-independent logic: parsing, timer state machine, formatting.
        .target(name: "DriftCore"),
        // The macOS app: AppKit + SwiftUI shell around DriftCore.
        .executableTarget(
            name: "Drift",
            dependencies: ["DriftCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "DriftCoreTests", dependencies: ["DriftCore"]),
    ]
)
