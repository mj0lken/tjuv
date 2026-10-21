// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tjuv",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Tjuv",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "TjuvTests",
            dependencies: ["Tjuv"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
