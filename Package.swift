// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DarkMic",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DarkMic", targets: ["DarkMic"])
    ],
    targets: [
        .executableTarget(
            name: "DarkMic",
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
