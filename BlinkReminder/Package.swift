// swift-tools-version: 5.9
import PackageDescription

// BlinkCore  : 플랫폼 독립 로직 (히스테리시스, 통계, EAR 계산, 오버레이 정책). iPad 타깃에서도 그대로 재사용.
// BlinkReminder : macOS 메뉴바 앱 (AppKit/SwiftUI/AVFoundation/Vision). macOS 에서만 빌드.
var targets: [Target] = [
    .target(name: "BlinkCore"),
    .testTarget(name: "BlinkCoreTests", dependencies: ["BlinkCore"]),
]
var products: [Product] = [
    .library(name: "BlinkCore", targets: ["BlinkCore"]),
]
#if os(macOS)
targets.append(.executableTarget(name: "BlinkReminder", dependencies: ["BlinkCore"], path: "Sources/BlinkReminder"))
products.append(.executable(name: "BlinkReminder", targets: ["BlinkReminder"]))
#endif

let package = Package(
    name: "BlinkReminder",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
