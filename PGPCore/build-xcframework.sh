#!/bin/sh
# Builds PGPCore (Rust, rPGP) as PGPCoreFFI.xcframework for iOS device,
# iOS simulator and macOS (the macOS slice is only used by `swift test`).
set -eu
cd "$(dirname "$0")"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin >/dev/null
for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  cargo build --release --target "$target"
done

OUT=../Packages/MailEngine/Frameworks/PGPCoreFFI.xcframework
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libpgpcore.a -headers include \
  -library target/aarch64-apple-ios-sim/release/libpgpcore.a -headers include \
  -library target/aarch64-apple-darwin/release/libpgpcore.a -headers include \
  -output "$OUT"
echo "Built $OUT"
