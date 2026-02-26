// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ConfigurationSharing",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "ConfigurationSharing",
            targets: ["ConfigurationSharing"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.7.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.3")
    ],
    targets: [
        .target(
            name: "ConfigurationSharing",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "ConfigurationSharingTests",
            dependencies: [
                "ConfigurationSharing",
                .product(name: "Dependencies", package: "swift-dependencies")
            ]
        )
    ]
)
