// swift-tools-version: 5.8
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .iOSApplication(
            name: "Velora",
            targets: ["Velora"],
            bundleIdentifier: "com.velora.aistudio",
            displayVersion: "1.0",
            bundleVersion: "1",
            iconAssetName: "AppIcon",
            accentColorAssetName: "AccentColor",
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown
            ],
            capabilities: [
                .backgroundMode(.audio)
            ]
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
