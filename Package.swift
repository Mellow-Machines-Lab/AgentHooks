// swift-tools-version: 6.0
import PackageDescription

// agent-hooks: what your coding agents are doing, from their hooks
// (README.md). Foundation only, and nothing outside this folder: apps
// depend on it, never the other way round.
let package = Package(
    name: "agent-hooks",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentHooks", targets: ["AgentHooks"]),
        .executable(name: "agent-hook", targets: ["AgentHookClient"]),
        .executable(name: "agent-hooks", targets: ["AgentHooksCLI"]),
    ],
    targets: [
        // What the hook client and the library share: the hook line, the
        // socket, topic tags, error classes, thread names and the host app.
        // Kept small so the client starts fast.
        .target(name: "AgentHooksWire"),
        // What apps link: events, sessions and "needs you", the listener,
        // the installer and thread links.
        .target(name: "AgentHooks", dependencies: ["AgentHooksWire"]),
        // `agent-hook claude|codex`: the command every hook entry runs.
        .executableTarget(name: "AgentHookClient", dependencies: ["AgentHooksWire"]),
        // `agent-hooks install|remove|status|tail|doctor`.
        .executableTarget(name: "AgentHooksCLI", dependencies: ["AgentHooks"]),
        // Real and synthetic hook payloads are in Tests/AgentHooksTests/Fixtures,
        // read from the source tree.
        .testTarget(name: "AgentHooksTests", dependencies: ["AgentHooks", "AgentHooksWire"],
                    exclude: ["Fixtures"]),
    ]
)
