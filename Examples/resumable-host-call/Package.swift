// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "resumable-host-call",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(name: "WasmKit", path: "../../")
    ],
    targets: [
        .target(
            name: "ResumableEmbedding",
            dependencies: [
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
            ]
        ),
        .executableTarget(name: "resumable-host-call", dependencies: ["ResumableEmbedding"]),
        .testTarget(name: "ResumableEmbeddingTests", dependencies: ["ResumableEmbedding"]),
    ]
)
