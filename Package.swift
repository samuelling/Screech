// swift-tools-version:5.9
// The note modem core as a Swift package, so it can be tested with `swift test` on macOS or Linux.
// The iPhone app compiles the same files (Screech/Core) directly.
import PackageDescription

let package = Package(
    name: "ScreechCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "ScreechCore", targets: ["ScreechCore"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")],
    targets: [
        .target(name: "ScreechCore",
                dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
                path: "Screech/Core"),
        .testTarget(name: "ScreechCoreTests", dependencies: ["ScreechCore"], path: "Tests/ScreechCoreTests",
                    exclude: ["Fixtures"]),
        .executableTarget(name: "screech-cli", dependencies: ["ScreechCore"], path: "tools/cli"),
    ]
)
