// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HTMLtoDOCX",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HTMLtoDOCX", targets: ["HTMLtoDOCX"])
    ],
    targets: [
        .executableTarget(
            name: "HTMLtoDOCX",
            path: "Sources/HTMLtoDOCX"
        )
    ]
)
