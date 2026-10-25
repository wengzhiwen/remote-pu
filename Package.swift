// swift-tools-version:6.0
// Builds with the macOS Command Line Tools alone (`swift build`); scripts/mac.sh
// assembles RemotePU.app. Tests use swift-testing, which needs the Xcode toolchain
// (scripts/mac.sh test sets DEVELOPER_DIR when Xcode.app exists).
import PackageDescription

let package = Package(
    name: "RemotePU",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RemotePU", targets: ["RemotePU"]),
        .executable(name: "rpu-agent-mac", targets: ["rpu-agent-mac"]),
        .executable(name: "rpu-askpass", targets: ["rpu-askpass"]),
        .executable(name: "rpuctl", targets: ["rpuctl"]),
        .executable(name: "rpu-probe", targets: ["rpu-probe"]),
    ],
    targets: [
        // Wire format shared by the Mac agent and the app (NDJSON v1).
        .target(name: "RPUProtocol"),
        // Unix-socket JSON-lines IPC + JSONValue, shared by app, rpuctl and rpu-askpass.
        .target(name: "RPUIPC"),
        // Everything non-UI: transports, node state machine, storage, control server.
        .target(
            name: "RemotePUCore",
            dependencies: ["RPUProtocol", "RPUIPC"],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]
        ),
        .executableTarget(
            name: "rpu-agent-mac",
            dependencies: ["RPUProtocol"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(name: "rpu-askpass", dependencies: ["RPUIPC"]),
        .executableTarget(name: "rpuctl", dependencies: ["RPUIPC"]),
        .executableTarget(name: "rpu-probe", dependencies: ["RemotePUCore"]),
        .executableTarget(
            name: "RemotePU",
            dependencies: ["RemotePUCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "RemotePUCoreTests", dependencies: ["RemotePUCore", "RPUProtocol", "RPUIPC"]),
    ],
    swiftLanguageModes: [.v5]
)
