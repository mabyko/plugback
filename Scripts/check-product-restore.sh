#!/bin/sh
# Product-contract probes kept separate from the current implementation's tests.
# Expected to fail until the gaps in docs/PRODUCT_DESIGN_REVIEW.md are addressed.
set -eu

review_repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
review_dir=$(mktemp -d "${TMPDIR:-/tmp}/plugback-product-review.XXXXXX")
trap 'rm -rf "$review_dir"' EXIT

mkdir -p "$review_dir/Sources" "$review_dir/Tests/PlugbackKitTests"
cp -R "$review_repo/Sources/PlugbackKit" "$review_dir/Sources/PlugbackKit"
cp "$review_repo/Tests/PlugbackKitTests/FakeWindowGateway.swift" \
    "$review_repo"/Tests/DesignReviewTests/*.swift \
    "$review_dir/Tests/PlugbackKitTests/"
cat > "$review_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PlugbackDesignReview",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PlugbackKit", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "PlugbackKitTests", dependencies: ["PlugbackKit"])
    ]
)
SWIFT

swift test --package-path "$review_dir" "$@"
