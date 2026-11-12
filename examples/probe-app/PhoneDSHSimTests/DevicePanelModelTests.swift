// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — device panel model tests (device-panel.md §2–§4).
//
// These drive the production `DevicePanelModel` through the scripted
// `FakeDevicePanelSource`. WP1–WP3 are placeholders on this base commit, so the
// fake supplies tools, descriptor evaluations and call outcomes; the suite
// never touches BLE, `callLinkTool`, `DevicePanelStore` or Application Support.
// This is simulator/fake evidence, not device evidence.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHBLE

@MainActor
final class DevicePanelModelTests: XCTestCase {
    private func editorsTool(_ name: String, _ editors: [DevicePanelEditor]) -> DevicePanelTool {
        DevicePanelTool(name: name, description: "\(name) 的设备说明", render: .editors(editors))
    }

    private func source(tools: [DevicePanelTool]? = nil) -> FakeDevicePanelSource {
        let tools = tools ?? [
            editorsTool("light.set", [.toggle(arg: "on", required: true)]),
            editorsTool("light.get", []),
            DevicePanelTool(name: "home.http", description: "http", render: .agentOnly),
        ]
        return FakeDevicePanelSource(tools: tools,
                                     grantedTools: Set(tools.map(\.name)))
    }

    // MARK: - No descriptor: the §2 tool list

    func testNoDescriptorListsToolsInAdvertisedOrder() {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()

        XCTAssertEqual(model.tools.map(\.name), ["light.set", "light.get", "home.http"],
                       "tools must keep tools/list order")
        XCTAssertEqual(model.tools[0].render, .editors([.toggle(arg: "on", required: true)]))
        XCTAssertEqual(model.tools[2].render, .agentOnly,
                       "agent_only tools are rendered only as name + 仅 Agent 可用")
        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.adoptedDescriptorResult)
        XCTAssertFalse(model.hasAdoptedDescriptor)
        XCTAssertTrue(model.controlGroups.isEmpty)
        XCTAssertTrue(fake.invocations.isEmpty, "opening the panel must not call any tool")
    }

    // MARK: - Adoption and fallback

    func testAdoptDescriptorShowsOnlyItsControlsInArrayAndGroupOrder() async {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()

        let bytes = Data(#"{"v":1,"device_id":"fake-device-id","controls":[]}"#.utf8)
        let descriptor = DevicePanelDescriptor(title: "书房", controls: [
            DevicePanelControl(tool: "light.set", label: "开灯", group: "灯光",
                               preset: .object(["on": .bool(true)])),
            DevicePanelControl(tool: "light.set", label: "关灯", group: "灯光",
                               preset: .object(["on": .bool(false)])),
            DevicePanelControl(tool: "light.get", label: "亮度", group: "状态"),
            DevicePanelControl(tool: "light.get", label: "温度"),
        ])
        fake.registerDescriptor(bytes, result: .ok, descriptor: descriptor)

        let result = await model.adoptDescriptor(bytes)
        XCTAssertEqual(result, .ok)
        XCTAssertEqual(model.descriptor, descriptor)
        XCTAssertTrue(model.hasAdoptedDescriptor)
        XCTAssertNil(model.adoptedDescriptorResult)
        XCTAssertEqual(model.controlGroups.map(\.title), ["灯光", "状态", nil],
                       "groups keep first-seen order, ungrouped included")
        XCTAssertEqual(model.controlGroups.map { $0.controls.count }, [2, 1, 1])
        XCTAssertEqual(model.controlGroups[0].controls.map(\.label), ["开灯", "关灯"],
                       "controls keep descriptor array order")
        XCTAssertEqual(model.controlGroups[2].title, nil, "ungrouped controls keep their own bucket")
        XCTAssertEqual(model.controlGroups[1].controls.first?.label, "亮度")
        XCTAssertTrue(fake.invocations.isEmpty, "adopting a descriptor must not call a tool")
        XCTAssertTrue(fake.queryCalls.isEmpty)
    }

    func testInvalidAdoptedDescriptorFallsBackToToolListWithReason() async throws {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()

        let bytes = Data(#"{"v":1,"device_id":"fake-device-id","controls":[]}"#.utf8)
        let descriptor = DevicePanelDescriptor(title: "书房", controls: [
            DevicePanelControl(tool: "light.set", label: "开灯",
                               preset: .object(["on": .bool(true)])),
        ])
        fake.registerDescriptor(bytes, result: .ok, descriptor: descriptor)
        let adopted = await model.adoptDescriptor(bytes)
        XCTAssertEqual(adopted, .ok)
        XCTAssertNotNil(model.descriptor)

        // The device's next tools/list no longer advertises the referenced
        // tool: re-evaluation must stop being .ok and the panel must fall back.
        fake.registerDescriptor(bytes, result: .tool_not_advertised)
        model.refresh()

        XCTAssertNil(model.descriptor)
        XCTAssertEqual(model.adoptedDescriptorResult, .tool_not_advertised)
        XCTAssertTrue(model.hasAdoptedDescriptor, "the host copy is kept for a later tools/list")
        XCTAssertEqual(model.tools.map(\.name), ["light.set", "light.get", "home.http"],
                       "the §2 tool list is shown again")
        XCTAssertTrue(fake.invocations.isEmpty)
        XCTAssertTrue(fake.queryCalls.isEmpty)
    }

    func testRemoveDescriptorReturnsToToolList() async {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()
        let bytes = Data(#"{"v":1,"device_id":"fake-device-id","controls":[]}"#.utf8)
        fake.registerDescriptor(bytes, result: .ok, descriptor: DevicePanelDescriptor(title: "书房", controls: [
            DevicePanelControl(tool: "light.get", label: "状态"),
        ]))
        let adopted = await model.adoptDescriptor(bytes)
        XCTAssertEqual(adopted, .ok)

        let removed = await model.removeDescriptor()
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.removalCount, 1)
        XCTAssertNil(model.descriptor)
        XCTAssertNil(model.adoptedDescriptorResult)
        XCTAssertFalse(model.hasAdoptedDescriptor)
        XCTAssertEqual(model.tools.map(\.name), ["light.set", "light.get", "home.http"])
        XCTAssertTrue(fake.invocations.isEmpty)
    }

    // MARK: - Call outcomes

    func testNotExecutedShowsStatusAndAllowsResendWithANewKey() async throws {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()
        let preset = JSONValue.object(["on": .bool(true)])
        fake.invokeOutcomes = [
            .notExecuted(requestID: UUID(), stage: "commit", status: "STORE_FULL"),
            .completed(requestID: UUID(), reply: .object(["status": .string("completed"),
                                                          "result": .object(["on": .bool(true)])])),
        ]

        await model.send(toolName: "light.set", preset: preset)
        let first = try XCTUnwrap(model.lastResults["light.set"]?.state)
        guard case .notExecuted(_, let status) = first else {
            return XCTFail("expected not_executed, got \(first)")
        }
        XCTAssertEqual(status, "STORE_FULL")
        XCTAssertTrue(model.canSend(toolName: "light.set", preset: preset),
                      "not_executed explicitly allows a new call")

        await model.send(toolName: "light.set", preset: preset)
        XCTAssertEqual(fake.invocations.count, 2)
        XCTAssertEqual(Set(fake.invocations.map(\.idempotencyKey)).count, 2,
                       "every tap generates a new idempotency key")
        for call in fake.invocations {
            XCTAssertEqual(call.idempotencyKey, call.idempotencyKey.lowercased())
            XCTAssertNotNil(UUID(uuidString: call.idempotencyKey))
            XCTAssertEqual(call.arguments, preset, "a preset is sent exactly as written")
        }
        let second = try XCTUnwrap(model.lastResults["light.set"]?.state)
        guard case .completed = second else {
            return XCTFail("expected completed, got \(second)")
        }
    }

    func testOutcomeUnknownQueriesAndNeverRetriesAutomatically() async throws {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()
        let preset = JSONValue.object(["on": .bool(true)])
        let requestID = UUID()
        fake.invokeOutcomes = [.outcomeUnknown(requestID: requestID, message: "connection lost")]
        fake.queryOutcomes = [.completed(requestID: requestID,
                                         reply: .object(["status": .string("completed"),
                                                         "result": .object(["on": .bool(true)])]))]

        await model.send(toolName: "light.set", preset: preset)
        XCTAssertEqual(fake.invocations.count, 1)
        XCTAssertTrue(fake.queryCalls.isEmpty, "outcome_unknown must not auto-query or auto-retry")
        let pending = try XCTUnwrap(model.lastResults["light.set"]?.state)
        guard case .outcomeUnknown = pending else {
            return XCTFail("expected outcome_unknown, got \(pending)")
        }
        XCTAssertTrue(model.canQuery(toolName: "light.set"))
        XCTAssertFalse(model.canSend(toolName: "light.set", preset: preset),
                       "outcome_unknown is query-only, not a resend")
        XCTAssertFalse(model.isBusy, "a completed send leaves no call in flight")

        await model.query(toolName: "light.set")
        XCTAssertEqual(fake.queryCalls, [requestID])
        XCTAssertEqual(fake.invocations.count, 1, "querying must never replay the tool")
        let completed = try XCTUnwrap(model.lastResults["light.set"]?.state)
        guard case .completed = completed else {
            return XCTFail("expected completed after query, got \(completed)")
        }
        XCTAssertTrue(model.canSend(toolName: "light.set", preset: preset),
                      "a completed result may be sent again")
    }

    // MARK: - Opening performs zero device calls

    func testOpeningAndRefreshingThePanelPerformZeroCalls() async {
        let fake = source()
        let model = DevicePanelModel(source: fake)
        model.refresh()
        model.refresh()
        await model.adoptDescriptor(Data("{}".utf8)) // invalid; still local only
        model.refresh()

        XCTAssertTrue(fake.invocations.isEmpty,
                      "opening/refreshing must not call any tool, including light.get")
        XCTAssertTrue(fake.queryCalls.isEmpty)
        XCTAssertEqual(fake.removalCount, 0)
        XCTAssertEqual(fake.adoptionAttempts.count, 1)
        XCTAssertEqual(fake.adoptionAttempts.last?.result, .invalid_json)
        XCTAssertNil(model.adoptedDescriptorResult)
        XCTAssertNil(model.descriptor)
    }

    // MARK: - Device identity is verbatim

    func testLinkDeviceIDIsExposedVerbatim() {
        let id = UUID()
        var device = BLEDeviceStore.Device(id: id, name: "test board", rssi: -40)
        device.linkDeviceID = "AbC-Device-ID"
        let store = BLEDeviceStore(testDevices: [device])
        let source = LiveDevicePanelSource(device: device, store: store)
        XCTAssertEqual(source.linkDeviceID, "AbC-Device-ID",
                       "the panel must never lowercase the Link device ID")
        XCTAssertEqual(DevicePanelModel(source: source).linkDeviceID, "AbC-Device-ID")
    }

    // MARK: - Editors are parameter inputs

    func testEditorsStartUnsetAndOnlySetParametersAreSent() async {
        let toggle = DevicePanelEditor.toggle(arg: "on", required: true)
        let slider = DevicePanelEditor.slider(arg: "brightness", required: false,
                                              integer: true, min: 0, max: 100)
        let picker = DevicePanelEditor.picker(arg: "mode", required: false,
                                              options: ["eco", "bright"])
        let fake = source(tools: [editorsTool("light.set", [toggle, slider, picker])])
        let model = DevicePanelModel(source: fake)
        model.refresh()

        XCTAssertNil(model.editorValue(tool: "light.set", argument: "on"))
        XCTAssertEqual(model.missingRequiredArguments(for: "light.set"), ["on"])
        XCTAssertFalse(model.canSend(toolName: "light.set", preset: nil),
                       "required editors must all be set before sending")

        model.setEditorValue(.picker("eco"), tool: "light.set", argument: "mode")
        XCTAssertFalse(model.canSend(toolName: "light.set", preset: nil))
        model.setEditorValue(.toggle(true), tool: "light.set", argument: "on")
        XCTAssertTrue(model.canSend(toolName: "light.set", preset: nil))
        XCTAssertEqual(model.argumentObject(for: "light.set"),
                       ["on": .bool(true), "mode": .string("eco")],
                       "an unset optional parameter is omitted from the request")

        await model.send(toolName: "light.set", preset: nil)
        XCTAssertEqual(fake.invocations.count, 1)
        XCTAssertEqual(fake.invocations[0].arguments,
                       .object(["on": .bool(true), "mode": .string("eco")]))
    }

    func testUnauthorizedToolCannotBeSent() async {
        let fake = source()
        fake.grantedTools = []
        let model = DevicePanelModel(source: fake)
        model.refresh()
        let preset = JSONValue.object(["on": .bool(true)])

        XCTAssertFalse(model.canSend(toolName: "light.set", preset: preset))
        await model.send(toolName: "light.set", preset: preset)
        XCTAssertTrue(fake.invocations.isEmpty)
        XCTAssertNotNil(model.errorText)
    }
}
