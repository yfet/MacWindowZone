// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacWindowZone",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacWindowZone", targets: ["MacWindowZone"])
    ],
    targets: [
        .executableTarget(
            name: "MacWindowZone",
            path: "Sources/MacWindowZone",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
