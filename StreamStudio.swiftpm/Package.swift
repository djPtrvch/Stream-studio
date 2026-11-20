// swift-tools-version: 5.9

// WARNING:
// This is a Swift Playgrounds app package. Playgrounds may rewrite parts of
// this file when you change App Settings (team, icon, bundle ID).

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Stream Studio",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Stream Studio",
            targets: ["AppModule"],
            bundleIdentifier: "com.streamstudio.app",
            displayVersion: "0.2",
            bundleVersion: "2",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.red),
            supportedDeviceFamilies: [
                .pad
            ],
            // iPad multitasking (Stage Manager / Split View) requires all orientations.
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .camera(purposeString: "Камеры используются для трансляции."),
                .microphone(purposeString: "Микрофон используется для трансляции.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
