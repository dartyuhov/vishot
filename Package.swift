// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vishot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "VishotRendering", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "VishotConfiguration",
            dependencies: ["VishotRendering", .product(name: "TOMLKit", package: "TOMLKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotConfigurationTests", dependencies: ["VishotConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "VishotAgent", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "VishotCLIExecution",
            dependencies: ["VishotAgent", "VishotRendering", "VishotConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "VishotCLI", dependencies: ["VishotCLIExecution"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Vishot",
            dependencies: ["VishotAgent", "VishotRendering", "VishotConfiguration", .product(name: "TOMLKit", package: "TOMLKit")],
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
            name: "VishotRenderingTests",
            dependencies: ["VishotRendering"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotCLIExecutionTests",
            dependencies: ["VishotCLIExecution", "VishotCLI", "VishotAgent", "VishotRendering", "VishotConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VishotTests",
            dependencies: ["Vishot", "VishotCLI", "VishotAgent", "VishotRendering", "VishotConfiguration"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
