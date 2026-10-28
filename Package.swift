// swift-tools-version: 5.10
// phone-dsh: run DeepSeek Harness unmodified inside an iOS/macOS app.
// Host SDK modules (MIT). Layout: one library product per module.
//
// PhoneDSHShell links the Rust accelerators (shell/) as an XCFramework only
// when PDSH_WITH_XZSHELL=1 (the historical spelling PDSH_WITH_SHELL=1 is also
// accepted) and the archive built by shell/build-apple.sh exists. Without the
// artifact it compiles against its pure-Swift stub of the C surface, so a
// missing XCFramework is reported as "not linked" instead of claiming
// accelerators that are not present.
import Foundation
import PackageDescription

struct Module {
    let name: String
    var dependencies: [Target.Dependency] = []
    var testDependencies: [Target.Dependency] = []
    var hasTests = true
    var resources: [Resource] = []
}

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let shellXCFramework = packageRoot.appendingPathComponent("shell/dist/PDSHShell.xcframework").standardizedFileURL
let shellEnvironment = ProcessInfo.processInfo.environment
let shellRequested = shellEnvironment["PDSH_WITH_XZSHELL"] == "1"
    || shellEnvironment["PDSH_WITH_SHELL"] == "1"
let withShell = shellRequested && FileManager.default.fileExists(atPath: shellXCFramework.path)

let modules: [Module] = [
    // Dependency boundary: the agent/provider abstractions the host modules use
    // (exec provider, credentials, harness session, DSH remote client).
    Module(name: "PhoneDSHAgentCore"),
    // Ordered-channel codec and golden vectors.
    Module(name: "PhoneDSHWire"),
    // WAL, epochs, materialized copy, overlay, recovery.
    Module(name: "PhoneDSHLog", dependencies: ["PhoneDSHWire"], testDependencies: ["PhoneDSHWire"]),
    // The single loopback origin: page, static, image/overlay, channel upgrade, /v1/http, MCP.
    Module(name: "PhoneDSHLoopback",
           dependencies: ["PhoneDSHWire", "PhoneDSHAgentCore"],
           testDependencies: ["PhoneDSHWire", "PhoneDSHAgentCore"]),
    // Model gateway: SSE pass-through, retry, response log, host credential injection.
    Module(name: "PhoneDSHGateway", dependencies: ["PhoneDSHAgentCore"], testDependencies: ["PhoneDSHAgentCore"]),
    // Host and step state machines, fence, side-effect ledger, budgets.
    Module(name: "PhoneDSHController",
           dependencies: ["PhoneDSHWire", "PhoneDSHLog"],
           testDependencies: ["PhoneDSHWire", "PhoneDSHLog"]),
    // WKWebView engine host.
    Module(name: "PhoneDSHEngine", dependencies: ["PhoneDSHLoopback"], testDependencies: ["PhoneDSHLoopback"]),
    // Read-only native accelerators (Rust shell/ crates) behind the exec provider.
    // Test-support library (G2-FIX-22): the scripted model upstream, smoke evidence readers, kill-matrix support
    // and the AppKit event pump shared by the Smoke/Scenario/Kill/Probe harnesses and the probe app's simulator
    // suites. Not part of the app-facing API.
    Module(name: "PhoneDSHHarness",
           dependencies: ["PhoneDSH", "PhoneDSHWire", "PhoneDSHLog", "PhoneDSHEngine", "PhoneDSHController", "PhoneDSHAgentCore"],
           hasTests: false, resources: [.copy("Resources/probe-site")]),
    // Scenario engine (W13): catalog decoding, workspace seeding, perturbations, assertions and evidence writers
    // shared by the macOS XCTest runner and the probe app's simulator/device runner. Test support, not app API.
    Module(name: "PhoneDSHScenario",
           dependencies: ["PhoneDSHHarness", "PhoneDSH", "PhoneDSHWire", "PhoneDSHLog", "PhoneDSHEngine",
                          "PhoneDSHController", "PhoneDSHGateway", "PhoneDSHAgentCore"],
           hasTests: false),
    Module(name: "PhoneDSHShell", dependencies: ["PhoneDSHAgentCore"], testDependencies: ["PhoneDSHAgentCore"]),
    // The app-process facade: PhoneDSHHost and the channel DSH transport.
    Module(name: "PhoneDSH",
           dependencies: ["PhoneDSHWire", "PhoneDSHLog", "PhoneDSHLoopback", "PhoneDSHGateway",
                          "PhoneDSHController", "PhoneDSHEngine", "PhoneDSHShell", "PhoneDSHAgentCore"],
           testDependencies: ["PhoneDSHWire", "PhoneDSHLog", "PhoneDSHLoopback", "PhoneDSHGateway",
                              "PhoneDSHController", "PhoneDSHEngine", "PhoneDSHShell", "PhoneDSHAgentCore"]),
]

var products: [Product] = modules.map { .library(name: $0.name, targets: [$0.name]) }
var targets: [Target] = modules.flatMap { m -> [Target] in
    let wired = withShell && m.name == "PhoneDSHShell"
    let dependencies = wired ? m.dependencies + [.target(name: "PDSHShellFFI")] : m.dependencies
    let swiftSettings: [SwiftSetting] = wired ? [.define("PDSH_WITH_XZSHELL")] : []
    var t: [Target] = [m.resources.isEmpty
        ? .target(name: m.name, dependencies: dependencies, swiftSettings: swiftSettings)
        : .target(name: m.name, dependencies: dependencies, resources: m.resources, swiftSettings: swiftSettings)]
    if m.hasTests {
        t.append(.testTarget(name: "\(m.name)Tests",
                             dependencies: [.target(name: m.name)] + m.testDependencies,
                             swiftSettings: withShell && (m.name == "PhoneDSHShell" || m.name == "PhoneDSH")
                                ? [.define("PDSH_WITH_XZSHELL")] : []))
    }
    return t
}

// macOS end-to-end smoke: real WKWebView, real packed Worker image, scripted model (scripts/ci/smoke.sh).
targets.append(.testTarget(
    name: "PhoneDSHSmokeTests",
    dependencies: [.target(name: "PhoneDSHHarness"), .target(name: "PhoneDSH"), .target(name: "PhoneDSHWire"), .target(name: "PhoneDSHLog"),
                   .target(name: "PhoneDSHEngine"), .target(name: "PhoneDSHController"), .target(name: "PhoneDSHAgentCore")]))
// Phase 0 probes, JavaScriptCore/WKWebView benchmark, 100-file checkpoint, WAL kill matrix (scripts/ci/probes.sh).
targets.append(.testTarget(
    name: "PhoneDSHProbeTests",
    dependencies: [.target(name: "PhoneDSHHarness"), .target(name: "PhoneDSHLoopback"), .target(name: "PhoneDSHEngine"),
                   .target(name: "PhoneDSHLog"), .target(name: "PhoneDSHWire")]))
targets.append(.testTarget(
    name: "PhoneDSHKillTests",
    dependencies: [.target(name: "PhoneDSHHarness"), .target(name: "PhoneDSH"), .target(name: "PhoneDSHWire"), .target(name: "PhoneDSHLog"),
                   .target(name: "PhoneDSHController"), .target(name: "PhoneDSHEngine"), .target(name: "PhoneDSHLoopback"),
                   .target(name: "PhoneDSHAgentCore")]))
// Catalog-driven real-model scenario runner (scripts/ci/scenarios.sh); reuses the smoke's scripted upstream.
targets.append(.testTarget(
    name: "PhoneDSHScenarioTests",
    dependencies: [.target(name: "PhoneDSHScenario")]))

if withShell {
    targets.append(.binaryTarget(name: "PDSHShellFFI", path: "shell/dist/PDSHShell.xcframework"))
}

let package = Package(
    name: "PhoneDSH",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    targets: targets
)
