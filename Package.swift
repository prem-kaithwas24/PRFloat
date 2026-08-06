// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PRFloat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PRFloat", targets: ["PRFloat"]),
        .executable(name: "PRFloatCoreValidate", targets: ["PRFloatCoreValidate"]),
        .library(name: "PRFloatCore", targets: ["PRFloatCore"])
    ],
    targets: [
        .target(
            name: "PRFloatCore",
            path: "Sources/PRFloatCore"
        ),
        .executableTarget(
            name: "PRFloat",
            dependencies: ["PRFloatCore"],
            path: "Sources/PRFloat"
        ),
        .executableTarget(
            name: "PRFloatCoreValidate",
            dependencies: ["PRFloatCore"],
            path: "Sources/PRFloatCoreValidate"
        ),
        .testTarget(
            name: "PRFloatTests",
            dependencies: ["PRFloatCore"],
            path: "Tests/PRFloatTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
