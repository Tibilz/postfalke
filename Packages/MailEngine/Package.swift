// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MailEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MailEngine", targets: ["MailEngine"]),
    ],
    targets: [
        // Built from ../../PGPCore by PGPCore/build-xcframework.sh
        .binaryTarget(name: "PGPCoreFFI", path: "Frameworks/PGPCoreFFI.xcframework"),
        .target(name: "MailEngine", dependencies: ["PGPCoreFFI"]),
        .testTarget(name: "MailEngineTests", dependencies: ["MailEngine"]),
    ]
)
