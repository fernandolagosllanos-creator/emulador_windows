// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Paralelo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VMKit", targets: ["VMKit"]),
        .executable(name: "paralelo", targets: ["paralelo"]),
        .executable(name: "ParaleloApp", targets: ["ParaleloApp"]),
    ],
    targets: [
        .target(name: "VMKit"),
        .executableTarget(name: "paralelo", dependencies: ["VMKit"]),
        .executableTarget(name: "ParaleloApp", dependencies: ["VMKit"]),
        .testTarget(name: "VMKitTests", dependencies: ["VMKit"]),
    ]
)
