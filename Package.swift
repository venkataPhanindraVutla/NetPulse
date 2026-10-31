// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetPulse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetPulseCore", targets: ["NetPulseCore"]),
        .executable(name: "netpulse-probe", targets: ["netpulse-probe"]),
    ],
    targets: [
        .target(
            name: "NetPulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "netpulse-probe",
            dependencies: ["NetPulseCore"]
        ),
        .testTarget(
            name: "NetPulseCoreTests",
            dependencies: ["NetPulseCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
