// swift-tools-version: 6.2
//
// Builds the `mport` command-line tool with Swift Package Manager, without Xcode:
//
//     swift build -c release
//     .build/release/mport --help
//
// Development (and the tests) use mport.xcodeproj: its test target compiles the app's sources directly, which a
// package can't express, so the tests aren't declared here. The settings below mirror the Xcode target's.

import PackageDescription

let package = Package(
    name: "mport",
    platforms: [
        .macOS("26.5")
    ],
    products: [
        .executable(name: "mport", targets: ["mport"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten", from: "7.16.3"),
        .package(url: "https://github.com/tuist/Noora", from: "0.57.2")
    ],
    targets: [
        .executableTarget(
            name: "mport",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MongoKitten", package: "MongoKitten"),
                .product(name: "MongoClient", package: "MongoKitten"),
                .product(name: "Noora", package: "Noora")
            ],
            path: "mport",
            swiftSettings: [
                // SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES
                .enableUpcomingFeature("MemberImportVisibility"),
                // SWIFT_APPROACHABLE_CONCURRENCY = YES
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("InferSendableFromCaptures")
            ]
        )
    ],
    // SWIFT_VERSION = 5.0
    swiftLanguageModes: [.v5]
)
