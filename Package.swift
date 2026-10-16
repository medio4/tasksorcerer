// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TaskSorcerer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SorcererCore", targets: ["SorcererCore"]),
        .executable(name: "sorcerer", targets: ["sorcerer"]),
        .executable(name: "TaskSorcerer", targets: ["TaskSorcerer"]),
    ],
    targets: [
        .target(name: "SorcererCore"),
        .executableTarget(
            name: "sorcerer",
            dependencies: ["SorcererCore"],
            // Embed an Info.plist so macOS shows a usage description when asking for Reminders access.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", "Support/cli-Info.plist"])]
        ),
        .executableTarget(name: "TaskSorcerer", dependencies: ["SorcererCore"]),
        .testTarget(name: "SorcererCoreTests", dependencies: ["SorcererCore"]),
    ]
)
