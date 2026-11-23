// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Atoll",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Atoll",
            path: "Sources/Atoll",
            resources: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
