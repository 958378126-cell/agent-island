// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AgentIslandCore", targets: ["AgentIslandCore"]),
        .executable(name: "agent-island-selftest", targets: ["AgentIslandSelftest"]),
        .executable(name: "agent-island-tests", targets: ["AgentIslandTests"])
    ],
    targets: [
        .target(name: "AgentIslandCore"),
        .executableTarget(name: "AgentIslandSelftest", dependencies: ["AgentIslandCore"]),
        .executableTarget(name: "AgentIslandTests", dependencies: ["AgentIslandCore"])
    ]
)
