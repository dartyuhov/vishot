// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vishot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vishot",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
