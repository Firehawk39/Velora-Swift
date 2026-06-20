// swift-tools-version: 6.0
import PackageDescription

#if canImport(AppleProductTypes)
import AppleProductTypes

let products: [Product] = [
    .iOSApplication(
        name: "Velora",
        targets: ["AppModule"],
        bundleIdentifier: "com.velora.aistudio",
        teamIdentifier: "",
        displayVersion: "1.0",
        bundleVersion: "1",
        appIcon: .asset("AppIcon"),
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
]
#else
let products: [Product] = [
    .executable(
        name: "Velora",
        targets: ["AppModule"]
    )
]
#endif

let package = Package(
    name: "Velora",
    platforms: [
        .iOS(.v15)
    ],
    products: products,
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources/App",
            resources: [
                .process("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
