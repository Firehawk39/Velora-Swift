// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .executable(
            name: "Velora",
            targets: ["Velora"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Velora",
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
