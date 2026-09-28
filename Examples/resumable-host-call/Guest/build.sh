#!/bin/sh
# Builds resumable_guest.swift into an optimized WebAssembly reactor and prints its SHA-256.
#
# SWIFT_TOOLCHAIN is a Swift release toolchain and SWIFT_SDK the WebAssembly Swift SDK of the
# same release, installed with `swift sdk install`. The optional argument is the output path.
set -eu

SWIFT_TOOLCHAIN=${SWIFT_TOOLCHAIN:-$HOME/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain}
SWIFT_SDK=${SWIFT_SDK:-swift-6.3.2-RELEASE_wasm}
guest_dir=$(cd "$(dirname "$0")" && pwd)
output=${1:-$guest_dir/../.build/guest/resumable_guest.wasm}

configuration=$("$SWIFT_TOOLCHAIN/usr/bin/swift" sdk configure --show-configuration "$SWIFT_SDK" wasm32-unknown-wasip1)
sdk_root=$(printf '%s\n' "$configuration" | sed -n 's/^sdkRootPath: //p')
resources=$(printf '%s\n' "$configuration" | sed -n 's/^swiftStaticResourcesPath: //p')

mkdir -p "$(dirname "$output")"
set -x
"$SWIFT_TOOLCHAIN/usr/bin/swiftc" \
    -target wasm32-unknown-wasip1 \
    -sdk "$sdk_root" \
    -resource-dir "$resources" \
    -static-stdlib \
    -O \
    -parse-as-library \
    -enable-experimental-feature Extern \
    -Xclang-linker -resource-dir -Xclang-linker "$resources/clang" \
    -Xclang-linker -mexec-model=reactor \
    "$guest_dir/resumable_guest.swift" \
    -o "$output"
{ set +x; } 2>/dev/null
"$SWIFT_TOOLCHAIN/usr/bin/swiftc" --version 2>&1 | head -1
shasum -a 256 "$output"
