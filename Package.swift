// swift-tools-version:5.9
import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"])
]

let package = Package(
    name: "gugu",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation layer: infra (Config/Paths/Strings/Log) + domain基础
        // (PetState/Memory/GrowthStage/WorkRhythm/Audit/EventBus/Perception).
        // Compiler-enforced: this target may NOT depend on any feature module.
        .target(
            name: "GuguKernel",
            path: "Sources/GuguKernel",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "gugu",
            dependencies: ["GuguKernel"],
            path: "Sources/Gugu",
            swiftSettings: strictConcurrency,
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
