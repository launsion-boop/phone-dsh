// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PhoneDSHADB

// MARK: - Test doubles

/// Fake probe that answers from a fixed `host:port` open set and records every
/// dial so a test can prove the engine only touched configured ports.
private struct TVDiscoveryScriptedProbe: TVPortProbe {
    let open: Set<String>
    let log: TVDiscoveryProbeLog

    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        log.record(host: host, port: port, timeout: timeout)
        return open.contains("\(host):\(port)")
    }
}

/// A probe that never answers inside the test budget. The sleep runs in a
/// detached task so cancelling the scan does not wake it early; the scan is
/// expected to return because its own overall timeout fires.
private struct TVDiscoveryWedgedProbe: TVPortProbe {
    func isOpen(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let sleeper = Task.detached {
            try? await Task.sleep(for: .seconds(10))
            return false
        }
        return await sleeper.value
    }
}

private struct TVDiscoveryScriptedBrowser: TVBonjourBrowsing {
    var hits: [TVBonjourHit] = []

    func browse(types: [String], duration: Duration) async -> [TVBonjourHit] {
        hits
    }
}

private final class TVDiscoveryProbeLog: @unchecked Sendable {
    struct Dial: Equatable {
        let host: String
        let port: UInt16
        let timeout: Duration
    }

    private let lock = NSLock()
    private var dials: [Dial] = []

    func record(host: String, port: UInt16, timeout: Duration) {
        lock.withLock {
            dials.append(Dial(host: host, port: port, timeout: timeout))
        }
    }

    var all: [Dial] {
        lock.withLock { dials }
    }
}

// MARK: - Tests

final class TVDiscoveryTests: XCTestCase {
    // MARK: Merge

    func testMergeFoldsADBAndXiaomiServicePortsIntoOneCandidate() throws {
        let merged = TVCandidateMerge.merge(
            hosts: ["192.0.2.20"],
            openPorts: ["192.0.2.20": [5555, 6095]],
            bonjour: [],
            remembered: [],
            config: discoveryConfig())

        XCTAssertEqual(merged.count, 1, "one host must produce one candidate, not one per port")
        let candidate = try XCTUnwrap(merged.first)
        XCTAssertEqual(candidate.id, "192.0.2.20:5555")
        XCTAssertEqual(candidate.host, "192.0.2.20")
        XCTAssertEqual(candidate.port, 5555)
        XCTAssertEqual(candidate.score, 100)
        XCTAssertEqual(candidate.kind, .androidTV)
        XCTAssertEqual(candidate.evidence, Set([.port(5555), .port(6095)]))
        XCTAssertEqual(candidate.authorization, .unknown)
    }

    func testPortEvidenceScoresAndCastKind() throws {
        let config = discoveryConfig()

        let adbOnly = TVCandidateMerge.merge(
            hosts: ["192.0.2.21"], openPorts: ["192.0.2.21": [5555]],
            bonjour: [], remembered: [], config: config)
        XCTAssertEqual(adbOnly.map { $0.score }, [80])

        let xiaomiOnly = TVCandidateMerge.merge(
            hosts: ["192.0.2.22"], openPorts: ["192.0.2.22": [6095]],
            bonjour: [], remembered: [], config: config)
        XCTAssertEqual(xiaomiOnly.map { $0.score }, [60])
        XCTAssertEqual(xiaomiOnly.first?.kind, .androidTV)

        let castHit = TVBonjourHit(service: "_googlecast._tcp", name: "Living Room",
                                   host: "192.0.2.23", port: 8009)
        let castOnly = TVCandidateMerge.merge(
            hosts: ["192.0.2.23"], openPorts: [:],
            bonjour: [castHit], remembered: [], config: config)
        XCTAssertEqual(castOnly.map { $0.score }, [50])
        let cast = try XCTUnwrap(castOnly.first)
        XCTAssertEqual(cast.kind, .cast)
        XCTAssertEqual(cast.id, "192.0.2.23:5555", "candidates always propose the ADB endpoint")
        XCTAssertEqual(cast.displayName, "Living Room")
        XCTAssertEqual(cast.evidence, Set([.bonjour("_googlecast._tcp")]))
    }

    func testRememberedDeviceScoresSeventyAndKeepsLiveScore() throws {
        let config = discoveryConfig()
        func remembered(host: String, serial: String) -> TVCandidate {
            TVCandidate(id: "\(host):5555", host: host, port: 5555, displayName: "Bedroom TV",
                        kind: .androidTV, evidence: [.remembered(serial)], score: 70,
                        authorization: .granted)
        }

        let alone = TVCandidateMerge.merge(
            hosts: ["192.0.2.40"], openPorts: [:], bonjour: [],
            remembered: [remembered(host: "192.0.2.40", serial: "SERIAL-A")], config: config)
        XCTAssertEqual(alone.count, 1)
        let rememberedCandidate = try XCTUnwrap(alone.first)
        XCTAssertEqual(rememberedCandidate.score, 70)
        XCTAssertEqual(rememberedCandidate.displayName, "Bedroom TV")
        XCTAssertTrue(rememberedCandidate.evidence.contains(.remembered("SERIAL-A")))

        // A remembered record raises weak evidence to 70 but never downgrades a
        // live ADB observation at 80.
        let withADB = TVCandidateMerge.merge(
            hosts: ["192.0.2.41"], openPorts: ["192.0.2.41": [5555]], bonjour: [],
            remembered: [remembered(host: "192.0.2.41", serial: "SERIAL-B")], config: config)
        let adbCandidate = try XCTUnwrap(withADB.first)
        XCTAssertEqual(adbCandidate.score, 80)
        XCTAssertTrue(adbCandidate.evidence.contains(.remembered("SERIAL-B")))
        XCTAssertTrue(adbCandidate.evidence.contains(.port(5555)))

        let withCast = TVCandidateMerge.merge(
            hosts: ["192.0.2.42"], openPorts: [:],
            bonjour: [TVBonjourHit(service: "_googlecast._tcp", name: "Cast",
                                   host: "192.0.2.42", port: 8009)],
            remembered: [remembered(host: "192.0.2.42", serial: "SERIAL-C")], config: config)
        XCTAssertEqual(withCast.first?.score, 70)
    }

    func testRememberedOnlyCandidateKeepsTheSavedPort() throws {
        let config = discoveryConfig()
        let saved = TVCandidate(id: "192.0.2.43:5556", host: "192.0.2.43", port: 5556,
                                displayName: "Study TV", kind: .androidTV,
                                evidence: [.remembered("SERIAL-D")], score: 70,
                                authorization: .granted)
        let alone = TVCandidateMerge.merge(
            hosts: ["192.0.2.43"], openPorts: [:], bonjour: [], remembered: [saved], config: config)
        let candidate = try XCTUnwrap(alone.first)
        XCTAssertEqual(candidate.port, 5556, "a remembered target keeps the port it was saved with")
        XCTAssertEqual(candidate.id, "192.0.2.43:5556")

        // A live 5555 answer overrides the stored port: that is the endpoint
        // ADB will actually dial after the scan.
        let withADB = TVCandidateMerge.merge(
            hosts: ["192.0.2.43"], openPorts: ["192.0.2.43": [5555]], bonjour: [],
            remembered: [saved], config: config)
        XCTAssertEqual(withADB.first?.port, 5555)
        XCTAssertEqual(withADB.first?.id, "192.0.2.43:5555")
    }

    func testCandidatesAreRankedDescendingWithUniqueIDs() {
        let merged = TVCandidateMerge.merge(
            hosts: ["192.0.2.58", "192.0.2.59", "192.0.2.60", "192.0.2.61",
                    "192.0.2.62", "192.0.2.63"],
            openPorts: [
                "192.0.2.58": [5555, 6095],
                "192.0.2.59": [5555],
                "192.0.2.61": [6095],
                "192.0.2.63": [8009],
            ],
            bonjour: [TVBonjourHit(service: "_googlecast._tcp", name: "Cast",
                                   host: "192.0.2.62", port: 8009)],
            remembered: [
                TVCandidate(id: "192.0.2.60:5555", host: "192.0.2.60", port: 5555,
                            displayName: "Den TV", kind: .androidTV,
                            evidence: [.remembered("SERIAL-C")], score: 70,
                            authorization: .granted),
            ],
            config: discoveryConfig())

        XCTAssertEqual(merged.map { $0.score }, [100, 80, 70, 60, 50, 40])
        XCTAssertEqual(merged.map { $0.id }, [
            "192.0.2.58:5555", "192.0.2.59:5555", "192.0.2.60:5555",
            "192.0.2.61:5555", "192.0.2.62:5555", "192.0.2.63:5555",
        ])
        XCTAssertEqual(Set(merged.map { $0.id }).count, merged.count)
    }

    // MARK: Engine

    func testEngineDialsOnlyConfiguredPortsAndMergesResults() async {
        let log = TVDiscoveryProbeLog()
        let config = discoveryConfig(
            ports: [5555, 6095], concurrency: 2,
            connectTimeout: .milliseconds(50),
            overallTimeout: .seconds(3), bonjourDuration: .milliseconds(1))
        let engine = TVDiscoveryEngine(
            config: config,
            probe: TVDiscoveryScriptedProbe(
                open: ["192.0.2.50:5555", "192.0.2.51:6095"], log: log),
            browser: TVDiscoveryScriptedBrowser())

        let results = await engine.scan(hosts: ["192.0.2.50", "192.0.2.51"])

        let dials = log.all
        XCTAssertEqual(dials.count, 4, "two hosts x two configured ports")
        XCTAssertEqual(Set(dials.map { $0.host }), ["192.0.2.50", "192.0.2.51"])
        XCTAssertEqual(Set(dials.map { $0.port }), [5555, 6095])
        XCTAssertEqual(Set(dials.map { "\($0.host):\($0.port)" }).count, 4,
                       "every host/port pair must be dialed exactly once")
        XCTAssertTrue(dials.allSatisfy { $0.timeout == config.connectTimeout },
                      "the probe must receive the configured connect timeout")

        XCTAssertEqual(results.map { $0.host }, ["192.0.2.50", "192.0.2.51"])
        XCTAssertEqual(results.map { $0.score }, [80, 60])
        XCTAssertEqual(results.map { $0.kind }, [.unknown, .androidTV])
        XCTAssertEqual(results.map { $0.evidence }, [
            Set([.port(5555)]), Set([.port(6095)]),
        ])
    }

    func testEngineDialsTheADBPortAcrossAllHostsBeforeWeakerPorts() async {
        let log = TVDiscoveryProbeLog()
        let config = discoveryConfig(
            ports: [5555, 6095], concurrency: 1,
            connectTimeout: .milliseconds(20),
            overallTimeout: .seconds(3), bonjourDuration: .milliseconds(1))
        let engine = TVDiscoveryEngine(
            config: config,
            probe: TVDiscoveryScriptedProbe(open: [], log: log),
            browser: TVDiscoveryScriptedBrowser())

        _ = await engine.scan(hosts: ["192.0.2.201", "192.0.2.202", "192.0.2.203"])

        XCTAssertEqual(log.all.map { $0.port },
                       [5555, 5555, 5555, 6095, 6095, 6095],
                       "the ADB port must be dialed across every host before weaker ports")
    }

    func testScanReturnsWhenOverallTimeoutExpires() async {
        let config = discoveryConfig(
            ports: [5555], concurrency: 1,
            connectTimeout: .seconds(30),
            overallTimeout: .milliseconds(200), bonjourDuration: .milliseconds(1))
        let engine = TVDiscoveryEngine(
            config: config, probe: TVDiscoveryWedgedProbe(),
            browser: TVDiscoveryScriptedBrowser())

        let clock = ContinuousClock()
        let start = clock.now
        let results = await engine.scan(hosts: ["192.0.2.90"])
        let elapsed = clock.now - start

        XCTAssertTrue(results.isEmpty, "no probe answered, so no candidate may be reported")
        XCTAssertLessThan(elapsed, .seconds(2),
                          "scan must return at its overall budget instead of awaiting a wedged probe")
    }

    // MARK: Helpers

    private func discoveryConfig(ports: [UInt16] = [5555, 6095], concurrency: Int = 2,
                                 connectTimeout: Duration = .milliseconds(50),
                                 overallTimeout: Duration = .seconds(2),
                                 bonjourDuration: Duration = .milliseconds(1)) -> TVDiscoveryConfig {
        TVDiscoveryConfig(ports: ports, concurrency: concurrency,
                          connectTimeout: connectTimeout, overallTimeout: overallTimeout,
                          bonjourTypes: ["_googlecast._tcp"],
                          bonjourDuration: bonjourDuration)
    }
}
