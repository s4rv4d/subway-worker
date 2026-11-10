// swift-tools-version: 6.2
import PackageDescription

/// UI-facing modules run everything on the main actor unless they opt out.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "SubwayWorker",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "SubwayWorker", targets: ["SubwayWorker"]),
    ],
    targets: [
        // Pure, testable logic: layout math, YouTube link parsing, clip models, coordinate conversion.
        .target(name: "SubwayWorkerCore"),

        // Moves/resizes other apps' windows through the Accessibility API.
        .target(
            name: "WindowTiling",
            dependencies: ["SubwayWorkerCore"],
            swiftSettings: mainActorByDefault
        ),

        // Plays local files, shuffled folders and YouTube embeds on a loop.
        .target(
            name: "ClipPlayback",
            dependencies: ["SubwayWorkerCore"],
            swiftSettings: mainActorByDefault
        ),

        // Built-in procedural "brainrot" loops that need no video file.
        .target(
            name: "ClipTemplates",
            dependencies: ["SubwayWorkerCore"],
            swiftSettings: mainActorByDefault
        ),

        // The app: launcher, session controller, gameplay panel, menu bar.
        .executableTarget(
            name: "SubwayWorker",
            dependencies: ["SubwayWorkerCore", "WindowTiling", "ClipPlayback", "ClipTemplates"],
            swiftSettings: mainActorByDefault
        ),

        .testTarget(name: "SubwayWorkerCoreTests", dependencies: ["SubwayWorkerCore"]),
    ]
)
