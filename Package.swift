// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiccoSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PiccoKit", targets: ["PiccoKit"]),
        .executable(name: "picco", targets: ["picco"]),
    ],
    targets: [
        .target(
            name: "PiccoKit",
            resources: [
                .copy("Resources/defuddle.js"),
                .copy("Resources/extract.js"),
                .copy("Resources/style.css"),
            ]
        ),
        .executableTarget(name: "picco", dependencies: ["PiccoKit"]),
        .testTarget(
            name: "PiccoKitTests",
            dependencies: ["PiccoKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
