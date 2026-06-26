// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentDashboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentDashboard",
            path: "AgentDashboard/Sources",
            resources: [
                .process("../Resources")
            ]
        )
    ]
)
