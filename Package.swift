// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "caff",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CaffCore", targets: ["CaffCore"]),
        .executable(name: "caff", targets: ["caff"]),
        .executable(name: "caff-core-checks", targets: ["CaffCoreChecks"])
    ],
    targets: [
        .target(
            name: "CaffCore",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "caff",
            dependencies: ["CaffCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CaffCoreChecks",
            dependencies: ["CaffCore"],
            path: "Checks/CaffCoreChecks"
        ),
        .testTarget(
            name: "CaffCoreTests",
            dependencies: ["CaffCore"]
        ),
        .testTarget(
            name: "CaffAppTests",
            dependencies: ["caff"]
        )
    ]
)
