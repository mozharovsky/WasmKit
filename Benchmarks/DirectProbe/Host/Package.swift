// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "DirectProbeHost",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "WasmKit", path: "../../.."),
    ],
    targets: [
        .executableTarget(
            name: "DirectProbeBench",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "WASI", package: "WasmKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
