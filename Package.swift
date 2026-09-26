// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KanbanCode",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .executable(name: "KanbanCode", targets: ["KanbanCode"]),
        .executable(name: "kanban-code-active-session", targets: ["KanbanCodeActiveSession"]),
        .executable(name: "kanban-code-remote-demo", targets: ["KanbanCodeRemoteDemo"]),
        .library(name: "KanbanCodeCore", targets: ["KanbanCodeCore"]),
        .library(name: "KanbanCodeRemoteKit", targets: ["KanbanCodeRemoteKit"]),
    ],
    dependencies: [
        .package(path: "LocalPackages/SwiftTerm"),
        // Vendored fork: see LocalPackages/swift-markdown-ui/FORK.md
        .package(path: "LocalPackages/swift-markdown-ui"),
    ],
    targets: [
        .executableTarget(
            name: "KanbanCode",
            dependencies: ["KanbanCodeCore", "SwiftTerm", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            path: "Sources/KanbanCode",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "KanbanCodeActiveSession",
            path: "Sources/KanbanCodeActiveSession"
        ),
        // Development server for the remote control clients: the real server over a fake board.
        .executableTarget(
            name: "KanbanCodeRemoteDemo",
            dependencies: ["KanbanCodeCore", "KanbanCodeRemoteKit"],
            path: "Sources/KanbanCodeRemoteDemo"
        ),
        .target(
            name: "KanbanCodeCore",
            dependencies: ["KanbanCodeRemoteKit"],
            path: "Sources/KanbanCodeCore"
        ),
        // Wire types of the remote control API, shared with the iOS app.
        .target(
            name: "KanbanCodeRemoteKit",
            path: "Sources/KanbanCodeRemoteKit"
        ),
        .testTarget(
            name: "KanbanCodeRemoteKitTests",
            dependencies: ["KanbanCodeRemoteKit"],
            path: "Tests/KanbanCodeRemoteKitTests"
        ),
        .testTarget(
            name: "KanbanCodeCoreTests",
            dependencies: ["KanbanCodeCore"],
            path: "Tests/KanbanCodeCoreTests"
        ),
        .testTarget(
            name: "KanbanCodeTests",
            dependencies: ["KanbanCode", "KanbanCodeCore"],
            path: "Tests/KanbanCodeTests"
        ),
    ]
)
