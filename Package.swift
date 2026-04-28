// swift-tools-version: 5.8

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Velora",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .iOSApplication(
            name: "Velora",
            targets: ["Velora"],
            bundleIdentifier: "com.velora.aistudio",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .note),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .portraitUpsideDown,
                .landscapeRight,
                .landscapeLeft
            ],
            additionalInfoPlistContentFilePath: "Info.plist"
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
