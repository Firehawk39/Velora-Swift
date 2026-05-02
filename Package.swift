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
            targets: ["AppModule"],
            bundleIdentifier: "com.velora.aistudio",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset(name: "AppIcon"),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown
            ]
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
