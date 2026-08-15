// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HeraldKit",
    platforms: [.macOS(.v15)],
    products: [.library(name: "HeraldKit", targets: ["HeraldKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
    ],
    targets: [
        // Leaf: generated client only. Nonisolated by default (see HeraldAPI.swift).
        .target(
            name: "HeraldAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .target(
            name: "HeraldKit",
            dependencies: [
                "HeraldAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HeraldKitTests",
            dependencies: ["HeraldKit"],
            swiftSettings: [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v6)]
        ),
    ]
)
