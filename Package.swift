// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TempControl",
    platforms: [.macOS(.v14)],
    targets: [
        // C shims: private IOHID sensor API declarations + classic SMC user-client calls.
        .target(
            name: "CShims",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Code shared by the app and the root helper (models, SMC wrapper, temp sensors).
        .target(
            name: "Shared",
            dependencies: ["CShims"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Samplers, snapshot collection and the per-panel report layer.
        // Shared by the menu bar app and the CLI so neither can drift from
        // the other. Deliberately NOT a dependency of the root helper.
        .target(
            name: "Dashboard",
            dependencies: ["Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app.
        .executableTarget(
            name: "TempControl",
            dependencies: ["Shared", "CShims", "Dashboard"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // One subcommand per dashboard panel, for humans and agents.
        .executableTarget(
            name: "tempcontrol-cli",
            dependencies: ["Dashboard", "Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Diagnostic CLI: prints what the sensors/SMC expose on this Mac.
        .executableTarget(
            name: "tempcontrol-probe",
            dependencies: ["Shared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The privileged helper daemon (runs as root via launchd).
        .executableTarget(
            name: "TempControlHelper",
            dependencies: ["Shared", "CShims"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
