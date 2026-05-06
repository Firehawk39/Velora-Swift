// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .executable(
            name: "Velora",
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
