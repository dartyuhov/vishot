// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vishot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Vishot",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotTests",
            dependencies: ["Vishot"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
