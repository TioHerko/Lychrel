// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LychrelKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LychrelKit", targets: ["LychrelKit"]),
    ],
    targets: [
        .target(
            name: "LychrelKit",
            swiftSettings: [
                // The packed BCD loop is SIMD, which unoptimized compiles every
                // vector op to a generic call (~3.6x slower than the old scalar
                // code), so build -O in Debug too. Aligning loops to 64 bytes
                // stops the same machine code running 25-30% slower depending
                // on where the hot loop lands.
                .unsafeFlags(["-O"], .when(configuration: .debug)),
                .unsafeFlags(["-Xllvm", "-align-loops=64"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
