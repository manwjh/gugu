// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gugu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "gugu",
            path: "Sources/Gugu",
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"])
            ],
            linkerSettings: [
                // Embed Info.plist so camera/mic usage strings are attributed.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
