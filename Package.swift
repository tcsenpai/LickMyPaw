// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "LickMyPaw",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "LickMyPaw", path: "Sources/LickMyPaw",
        resources: [.process("Resources")],
        swiftSettings: [.unsafeFlags(["-Ounchecked"])])]
)
