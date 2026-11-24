// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Doggo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Doggo",
            path: "Sources/Pip",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
