// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Folio", path: "Sources/Folio")
    ]
)
