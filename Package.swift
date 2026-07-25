// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitchMac",
    // A libusb do Homebrew é compilada com mínimo de macOS 14.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SwitchMac", targets: ["SwitchMac"])
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            path: "Sources/CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .target(name: "MTPKit", dependencies: ["CLibUSB"]),
        .executableTarget(name: "SwitchMac", dependencies: ["MTPKit"])
    ]
)
