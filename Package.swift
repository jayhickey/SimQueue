// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT

import PackageDescription

let argumentParser: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")

let package = Package(
    name: "SimQueue",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SimQueueCore", targets: ["SimQueueCore"]),
        .executable(name: "simq", targets: ["simq"]),
        .executable(name: "simqd", targets: ["simqd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // System SQLite: the macOS SDK on Darwin, libsqlite3-dev on Linux.
        .systemLibrary(
            name: "CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        // Pure models and policy. No I/O, no Darwin-only APIs, so it builds and tests on Linux.
        .target(name: "SimQueueCore"),
        // Wire types for the local socket protocol.
        .target(name: "SimQueueProtocol", dependencies: ["SimQueueCore"]),
        // SQLite-backed state.
        .target(name: "SimQueueStore", dependencies: ["SimQueueCore", "CSQLite"]),
        // Host resource probes (real probes are Darwin-only; fakes everywhere).
        .target(name: "SimQueueHost", dependencies: ["SimQueueCore"]),
        // Simulator backends: isolated fakes and owned real simulator operations.
        .target(name: "SimQueueSim", dependencies: ["SimQueueCore", "SimQueueHost"]),
        // One scheduling pass (probe, timeouts, plan, claim, explain) and reconcile.
        .target(
            name: "SimQueueEngine", dependencies: ["SimQueueCore", "SimQueueStore", "SimQueueHost", "SimQueueSim"]),
        // Unix socket transport (0600) and the client.
        .target(name: "SimQueueIPC", dependencies: ["SimQueueProtocol"]),
        // Opt-in MCP server (`simq mcp`): a thin wrapper over the socket protocol.
        .target(name: "SimQueueMCP", dependencies: ["SimQueueProtocol", "SimQueueIPC"]),
        // Daemon: request handling, run loop, single-instance lock, doctor, fake executor.
        .target(
            name: "SimQueueDaemon",
            dependencies: [
                "SimQueueCore", "SimQueueProtocol", "SimQueueStore", "SimQueueHost", "SimQueueSim", "SimQueueEngine",
                "SimQueueIPC",
            ]
        ),
        .executableTarget(
            name: "simq",
            dependencies: [
                "SimQueueCore", "SimQueueProtocol", "SimQueueIPC", "SimQueueMCP", "SimQueueStore", "SimQueueDaemon",
                "SimQueueHost",
                argumentParser,
            ]
        ),
        .executableTarget(
            name: "simqd",
            dependencies: [
                "SimQueueCore", "SimQueueStore", "SimQueueHost", "SimQueueSim", "SimQueueEngine", "SimQueueProtocol",
                "SimQueueIPC", "SimQueueDaemon", argumentParser,
            ]
        ),
        .testTarget(name: "SimQueueStoreTests", dependencies: ["SimQueueCore", "SimQueueStore"]),
        .testTarget(
            name: "SimQueueEngineTests",
            dependencies: [
                "SimQueueCore", "SimQueueStore", "SimQueueHost", "SimQueueSim", "SimQueueEngine", "SimQueueProtocol",
            ]
        ),
        .testTarget(
            name: "SimQueueDaemonTests",
            dependencies: [
                "SimQueueCore", "SimQueueStore", "SimQueueHost", "SimQueueSim", "SimQueueEngine", "SimQueueProtocol",
                "SimQueueIPC", "SimQueueDaemon", "SimQueueMCP",
            ]
        ),
        .testTarget(
            name: "SimQueueCoreTests",
            dependencies: [
                "SimQueueCore", "SimQueueProtocol", "SimQueueStore", "SimQueueHost", "SimQueueSim", "SimQueueEngine",
            ]
        ),
    ]
)
