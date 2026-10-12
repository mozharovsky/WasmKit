// swift-tools-version: 6.1

import PackageDescription

// A reactor module without a WASI command entry point. The host calls `_initialize` and then the
// exports listed here, which the linker would otherwise drop from an executable.
let exports = [
    "probe_compute", "probe_collections", "probe_text", "probe_tiny", "probe_chatter",
    "probe_long_action", "probe_spin", "probe_blocking",
]

let package = Package(
    name: "ProbeGuest",
    targets: [
        .executableTarget(
            name: "ProbeGuest",
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xclang-linker", "-mexec-model=reactor"]
                        + exports.flatMap { ["-Xlinker", "--export=\($0)"] }
                ),
            ]
        ),
    ]
)
