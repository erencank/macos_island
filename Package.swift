// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Island", targets: ["Island"]),
        .library(name: "IslandCore", targets: ["IslandCore"])
    ],
    targets: [
        .target(
            name: "IslandCore",
            path: "Sources/IslandCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "Island",
            dependencies: ["IslandCore"],
            path: "Sources/Island"
        ),
        .executableTarget(
            name: "IslandTestsRunner",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests"
        )
    ]
)
