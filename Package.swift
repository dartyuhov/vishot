// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vishot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "VishotAgent", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "VishotCLI", dependencies: ["VishotAgent"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Vishot",
            dependencies: ["VishotAgent", .product(name: "TOMLKit", package: "TOMLKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotAgentTests",
            dependencies: ["VishotAgent", "VishotCLI", "AgentServiceFixture"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentServiceFixture", dependencies: ["VishotAgent"], path: "Tests/AgentServiceFixture",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotTests",
            dependencies: ["Vishot", "VishotCLI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
