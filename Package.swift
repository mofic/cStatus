// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "cStatus",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "cStatus", targets: ["CStatus"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CStatusCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CStatus", dependencies: ["CStatusCore"]),
        .testTarget(name: "CStatusCoreTests", dependencies: ["CStatusCore", "CSQLite", "CStatus"])
    ]
)
