// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHDeviceTasks

private actor GuardInventoryTransport: DSHRemoteTransport {
    let rows: [JSONValue]
    var endpoints: [String] = []
    init(rows: [JSONValue]) { self.rows = rows }
    func call(_ endpoint: String, args: JSONValue) async throws -> JSONValue {
        endpoints.append(endpoint)
        if endpoint == "phone/pluginList" {
            return .object(["ok": .bool(true), "value": .object(["entries": .array(rows)])])
        }
        throw DeviceTaskError.invalidTask
    }
    func openMux() async throws -> any DSHMuxConnection { throw DeviceTaskError.invalidTask }
    func calls() -> [String] { endpoints }
}

final class DeviceDSHRunnerTests: XCTestCase {
    func testMissingOrInactiveGuardStopsBeforeSessionCreation() async throws {
        let base: [String: JSONValue] = ["entryId": .string("include:device-task-guard"),
            "moduleName": .string("@phone-dsh/dsh-lifecycle-gate/device-guard"),
            "enabled": .bool(true), "fiberPhase": .string("active")]
        var inactive = base
        inactive["fiberPhase"] = .string("failed")
        for rows: [JSONValue] in [[], [.object(inactive)], [.object(base), .object(base)]] {
            let transport = GuardInventoryTransport(rows: rows)
            let runner = DeviceDSHRunner(transport: transport)
            do {
                _ = try await runner.session(for: "device", existingSession: nil)
                XCTFail("unverified guard must fail closed")
            } catch { XCTAssertEqual(error as? DeviceTaskError, .unauthorized) }
            let calls = await transport.calls()
            XCTAssertEqual(calls, ["phone/pluginList"])
        }
    }
}
