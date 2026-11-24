// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InHerOwnWrite",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "InHerOwnWrite", targets: ["InHerOwnWrite"]),
    ],
    targets: [
        .target(name: "WriteCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "WriteApp", dependencies: ["WriteCore"]),
        .executableTarget(name: "InHerOwnWrite", dependencies: ["WriteApp"]),
        .executableTarget(name: "WriteCheck", dependencies: ["WriteCore", "WriteApp"]),
    ],
    swiftLanguageModes: [.v5]
)
