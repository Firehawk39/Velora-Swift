// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .iOSApplication(
            name: "Velora",
            targets: ["AppModule"],
            bundleIdentifier: "com.firehawk.velora",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            backgroundModes: [
                .audio,
                .fetch,
                .processing
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
