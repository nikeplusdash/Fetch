// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FetchKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FetchKit", targets: ["FetchKit"]),
        .library(name: "FetchPluginAPI", targets: ["FetchPluginAPI"]),
    ],
    targets: [
        .target(
            name: "FetchPluginAPI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FetchKit",
            dependencies: ["FetchPluginAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Renders the app icon into Assets.xcassets. An executable rather than
        // a loose script so it shares `AppIconArtwork` with the app, which
        // draws the same sky in the Dock with its clouds moved along.
        .executableTarget(
            name: "IconRenderer",
            dependencies: ["FetchKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FetchPluginAPITests",
            dependencies: ["FetchPluginAPI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FetchKitTests",
            dependencies: ["FetchKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
