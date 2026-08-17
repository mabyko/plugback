// swift-tools-version: 5.9
// 루트 고정 — SPM은 git 의존성의 매니페스트를 루트에서만 찾는다 (docs/ARCHITECTURE.md 패키지 경계).
import PackageDescription

let package = Package(
    name: "plugback",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PlugbackKit", targets: ["PlugbackKit"]),
        // 화면 식별자 실기기 스파이크용 프로브 (docs/ARCHITECTURE.md 마일스톤 M3)
        .executable(name: "screen-probe", targets: ["screen-probe"])
    ],
    targets: [
        // StrictConcurrency: 게이트웨이 심의 격리 계약을 컴파일러가 지킨다 (docs/ARCHITECTURE.md)
        .target(name: "PlugbackKit",
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "screen-probe", dependencies: ["PlugbackKit"],
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "PlugbackKitTests", dependencies: ["PlugbackKit"],
                    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ]
)
