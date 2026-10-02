// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentIslandCore", targets: ["AgentIslandCore"]),
        .executable(name: "AgentIsland", targets: ["AgentIsland"]),
        .executable(name: "agent-island-selftest", targets: ["AgentIslandSelftest"]),
        .executable(name: "agent-island-tests", targets: ["AgentIslandTests"])
    ],
    targets: [
        .target(name: "AgentIslandCore"),
        .executableTarget(name: "AgentIsland", dependencies: [], path: "Sources/AgentIsland"),
        .executableTarget(name: "AgentIslandSelftest", dependencies: ["AgentIslandCore"]),
        .executableTarget(name: "AgentIslandTests", dependencies: ["AgentIslandCore"])
    ]
)
