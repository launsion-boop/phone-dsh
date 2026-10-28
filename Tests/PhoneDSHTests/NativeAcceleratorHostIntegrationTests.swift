// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — Host EXEC integration for the native accelerators.
//
// This suite drives the real `PhoneDSHHost` assembly: the helper installs the
// linked `PDSHShellProvider`, the host HELLO must publish exactly the provider's
// names, and an EXEC_REQ from the scripted Worker must reach the Rust library
// and come back as an exec output/exit pair.

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLoopback
import PhoneDSHWire
import PhoneDSHAgentCore
import PhoneDSHShell

final class NativeAcceleratorHostIntegrationTests: XCTestCase {
    func testConfigurationHelperInstallsTheProviderAndItsNames() throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        var base = try fixture.configuration()
        base.handoff = HandoffClientConfiguration(endpoint: URL(string: "https://remote.example.test")!)
        XCTAssertNil(base.execProvider)
        XCTAssertTrue(base.acceleratorNames.isEmpty)

        let enabled = base.enablingNativeAccelerators()
        XCTAssertNotNil(enabled.execProvider)
        XCTAssertEqual(enabled.workspaceRoot, base.workspaceRoot)
        XCTAssertEqual(enabled.bundle, base.bundle)
        XCTAssertEqual(enabled.budgets, base.budgets)
        XCTAssertEqual(enabled.loopback, base.loopback)
        XCTAssertEqual(enabled.engine, base.engine)
        XCTAssertEqual(enabled.handoff, base.handoff)
        XCTAssertEqual(enabled.acceleratorNames, enabled.accelerators.acceleratorNames)
        XCTAssertEqual(enabled.acceleratorNames,
                       (enabled.execProvider as? PDSHShellProvider)?.acceleratorNames ?? [])
        XCTAssertNotEqual(base, enabled,
                          "the installed provider must change the configuration identity")
    }
}

#if PDSH_WITH_XZSHELL

final class NativeAcceleratorLinkedHostIntegrationTests: XCTestCase {
    func testHostHelloAndExecUseTheLinkedProvider() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration().enablingNativeAccelerators()
        let provider = try XCTUnwrap(configuration.execProvider as? PDSHShellProvider)
        XCTAssertTrue(provider.acceleratorNames.contains("rg"))
        XCTAssertFalse(provider.acceleratorNames.contains("phone"))
        XCTAssertFalse(provider.acceleratorNames.contains("ctx"))

        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()

        let caps = await engine.worker.hostHelloCapabilities()
        let helloCaps = try XCTUnwrap(caps)
        let advertised = Set(helloCaps.filter { $0.hasPrefix("accelerator:") })
        XCTAssertEqual(advertised,
                       Set(provider.acceleratorNames.map { "accelerator:\($0)" }))
        XCTAssertFalse(advertised.contains("accelerator:phone"))
        XCTAssertFalse(advertised.contains("accelerator:ctx"))
        XCTAssertTrue(advertised.contains("accelerator:rg"))

        let mseq = try await engine.worker.writeFile(
            path: "/dsh/workspace/native.txt",
            data: Data("alpha\nneedle here\n".utf8))
        try await engine.worker.waitForAck(mseq)
        let materialized = fixture.materializedFile("workspace/native.txt")
        try await waitUntil {
            guard let data = try? Data(contentsOf: materialized) else { return false }
            return String(decoding: data, as: UTF8.self).contains("needle")
        }

        try await engine.worker.requestExec(
            execID: "native-rg",
            idemKey: String(repeating: "a", count: 64),
            argv: ["rg", "--json", "needle"])
        try await engine.worker.waitForExecEvent("native-rg", type: "exit")

        let bodies = await engine.worker.execEventBodies()
        let output = try XCTUnwrap(bodies.first {
            $0.execID == "native-rg" && $0.type == "output"
        })
        let payload = try JSONValue.parse(output.body)
        let encoded = try XCTUnwrap(payload["data"]?.testString)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"type\":\"match\""), text)
        XCTAssertTrue(text.contains("needle"), text)
        try await host.stop()
    }

    func testHostHelloAndExecUseTheBridgeWhenInjected() async throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let bridge = ClosurePhoneToolBridge { name, arguments in
            "{\"name\":\"\(name)\",\"arguments\":\(arguments)}"
        }
        let configuration = try fixture.configuration()
            .enablingNativeAccelerators(toolBridge: bridge)
        let provider = try XCTUnwrap(configuration.execProvider as? PDSHShellProvider)
        XCTAssertTrue(provider.acceleratorNames.contains("phone"))
        XCTAssertTrue(provider.acceleratorNames.contains("ctx"))

        let engine = MockEngine(worker: MockWorker())
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()

        let caps = await engine.worker.hostHelloCapabilities()
        let helloCaps = try XCTUnwrap(caps)
        XCTAssertTrue(helloCaps.contains("accelerator:phone"))
        XCTAssertTrue(helloCaps.contains("accelerator:ctx"))

        try await engine.worker.requestExec(
            execID: "native-ctx",
            idemKey: String(repeating: "b", count: 64),
            argv: ["ctx", "weather", "in", "Oslo"])
        try await engine.worker.waitForExecEvent("native-ctx", type: "exit")

        let bodies = await engine.worker.execEventBodies()
        let output = try XCTUnwrap(bodies.first {
            $0.execID == "native-ctx" && $0.type == "output"
        })
        let payload = try JSONValue.parse(output.body)
        let encoded = try XCTUnwrap(payload["data"]?.testString)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ctx.query"), text)
        XCTAssertTrue(text.contains("weather in Oslo"), text)
        try await host.stop()
    }
}

#else

final class NativeAcceleratorStubHostIntegrationTests: XCTestCase {
    func testHelperWithoutTheLibraryAdvertisesNothing() throws {
        let fixture = try FacadeFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration().enablingNativeAccelerators()
        XCTAssertNotNil(configuration.execProvider)
        XCTAssertTrue(configuration.acceleratorNames.isEmpty)
        XCTAssertTrue(configuration.accelerators.acceleratorNames.isEmpty)
    }
}

#endif
