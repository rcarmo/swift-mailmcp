// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MailMCP",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MailMCP"),
        .testTarget(name: "MailMCPTests", dependencies: ["MailMCP"])
    ]
)
