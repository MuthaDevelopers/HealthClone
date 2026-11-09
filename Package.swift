// swift-tools-version:5.9
import PackageDescription

// BandKit holds everything that does not need an Apple framework: the wire
// protocol, the pairing handshake, activity sync and the on-disk day store.
// Keeping it free of CoreBluetooth and SwiftUI means it builds and is unit
// tested on Linux as well as on macOS, and the iOS app links the same code.
let package = Package(
    name: "BandKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "BandKit", targets: ["BandKit"]),
    ],
    targets: [
        .target(name: "BandKit", path: "Sources/BandKit"),
        .testTarget(name: "BandKitTests", dependencies: ["BandKit"], path: "Tests/BandKitTests"),
    ]
)
