// swift-tools-version: 5.9
// 루트 고정 — SPM은 git 의존성의 매니페스트를 루트에서만 찾는다 (docs/ARCHITECTURE.md 패키지 경계).
import PackageDescription

let package = Package(
    name: "plugback",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PlugbackKit", targets: ["PlugbackKit"])
    ],
    targets: [
        .target(name: "PlugbackKit"),
        .testTarget(name: "PlugbackKitTests", dependencies: ["PlugbackKit"])
    ]
)
