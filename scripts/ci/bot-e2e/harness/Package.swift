// swift-tools-version: 5.10
// SPDX-License-Identifier: MIT
//
// The macOS test package for the Bot evaluation runner (scripts/ci/bot-e2e).
// It exists so `swift test --disable-sandbox` can drive the same production
// sources the App uses: `Sources/BotEvalApp` contains only relative symlinks to
// `examples/probe-app/PhoneDSHProbe/Bot/**`, the shared ProbeKit host
// configuration and the bot-e2e turn-process shim. No production file is
// copied or forked here.

import PackageDescription

let root = "PhoneDSH"

let package = Package(
    name: "BotEvalHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: root, path: "../../../.."),
    ],
    targets: [
        .target(
            name: "BotEvalApp",
            dependencies: [
                .product(name: "PhoneDSH", package: root),
                .product(name: "PhoneDSHBot", package: root),
                .product(name: "PhoneDSHEngine", package: root),
                .product(name: "PhoneDSHDeviceTasks", package: root),
                .product(name: "PhoneDSHAgentCore", package: root),
                .product(name: "PhoneDSHController", package: root),
                .product(name: "PhoneDSHLoopback", package: root),
                .product(name: "PhoneDSHADB", package: root),
            ],
            path: "Sources/BotEvalApp"),
        .testTarget(
            name: "BotEvalTests",
            dependencies: [
                "BotEvalApp",
                .product(name: "PhoneDSH", package: root),
                .product(name: "PhoneDSHBot", package: root),
                .product(name: "PhoneDSHEngine", package: root),
                .product(name: "PhoneDSHHarness", package: root),
                .product(name: "PhoneDSHScenario", package: root),
                .product(name: "PhoneDSHAgentCore", package: root),
                .product(name: "PhoneDSHController", package: root),
                .product(name: "PhoneDSHLoopback", package: root),
                .product(name: "PhoneDSHADB", package: root),
                .product(name: "PhoneDSHDeviceTasks", package: root),
                .product(name: "PhoneDSHLog", package: root),
                .product(name: "PhoneDSHWire", package: root),
            ],
            path: "Tests/BotEvalTests"),
    ]
)
