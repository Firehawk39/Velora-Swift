// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "Velora",
            type: .executable,
            targets: ["AppModule"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
