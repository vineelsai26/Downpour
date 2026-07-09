// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Downpour",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "DownpourApp", targets: ["DownpourApp"]),
        .executable(name: "downpour", targets: ["downpour-cli"]),
        .executable(name: "backup-selftest", targets: ["backup-selftest"]),
    ],
    dependencies: [
        // Shared design system for the vstack macOS apps.
        .package(path: "../vkit"),
    ],
    targets: [
        .target(
            name: "BackupCore",
            path: "Sources/BackupCore"
        ),
        .executableTarget(
            name: "DownpourApp",
            dependencies: [
                "BackupCore",
                .product(name: "VKit", package: "vkit"),
            ],
            path: "Sources/DownpourApp"
        ),
        .executableTarget(
            name: "downpour-cli",
            dependencies: ["BackupCore"],
            path: "Sources/downpour-cli"
        ),
        // Standalone self-test runner. `swift test`/XCTest needs full Xcode,
        // which isn't assumed here, so logic tests run as a plain executable:
        //   swift run backup-selftest
        .executableTarget(
            name: "backup-selftest",
            dependencies: ["BackupCore"],
            path: "Sources/backup-selftest"
        ),
    ]
)
