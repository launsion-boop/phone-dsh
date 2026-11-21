// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore
import PhoneDSHDeviceTasks

/// device-panel.md §4.2: the first failure wins, in the order of the table.
public enum DevicePanelDescriptorResult: String, Equatable, Sendable, CaseIterable {
    case ok
    case too_large
    case invalid_json
    case duplicate_key
    case schema
    case unsupported_version
    case device_mismatch
    case tool_not_advertised
    case tool_not_supported
    case preset_invalid
}

/// One evaluated control. `preset` is the raw JSON object from the descriptor;
/// it is only meaningful for a button control (device-panel.md §4).
public struct DevicePanelControl: Equatable, Sendable {
    public var tool: String
    public var label: String
    public var group: String?
    public var preset: JSONValue?

    public init(tool: String, label: String, group: String? = nil, preset: JSONValue? = nil) {
        self.tool = tool
        self.label = label
        self.group = group
        self.preset = preset
    }
}

/// A descriptor that evaluated to `.ok`. Controls keep descriptor array order.
public struct DevicePanelDescriptor: Equatable, Sendable {
    public var title: String?
    public var controls: [DevicePanelControl]

    public init(title: String? = nil, controls: [DevicePanelControl]) {
        self.title = title
        self.controls = controls
    }
}

private let devicePanelDescriptorMaxBytes = 16_384
private let devicePanelDescriptorMaxDepth = 16
private let devicePanelDescriptorMaxControls = 32
private let devicePanelDescriptorMaxNameScalars = 64
private let devicePanelDescriptorMaxTextScalars = 40

/// One schema-validated descriptor control. `preset` is present only when the
/// descriptor carried the member (an empty object is a preset with no arguments).
private struct DevicePanelParsedControl {
    var tool: String
    var label: String
    var group: String?
    var preset: [String: JSONValue]?
}

private struct DevicePanelParsedDescriptor {
    var deviceID: String
    var title: String?
    var controls: [DevicePanelParsedControl]
}

/// device-panel.md §4.2: evaluate raw descriptor bytes against the Link device
/// ID and the device's current advertised tools. A descriptor value is returned
/// only for `.ok`; authorization is deliberately not part of evaluation (§4.2).
public func evaluateDevicePanelDescriptor(
    _ bytes: Data,
    linkDeviceID: String,
    tools: [JSONValue]
) -> (DevicePanelDescriptorResult, DevicePanelDescriptor?) {
    // 1. The limit is the UTF-8 byte count of the raw input.
    guard bytes.count <= devicePanelDescriptorMaxBytes else { return (.too_large, nil) }

    // 2. Must be a single valid UTF-8 JSON value. Foundation would accept a BOM
    //    or UTF-16/UTF-32 input; §4.2 says UTF-8, and the shared checker's
    //    reference implementation rejects a leading U+FEFF.
    guard let text = String(data: bytes, encoding: .utf8),
          text.utf8.elementsEqual(bytes),
          !text.hasPrefix("\u{FEFF}") else { return (.invalid_json, nil) }

    // Duplicate member names must be read from the raw bytes before Foundation
    // can drop them (the scan runs on the bytes, never on the parsed value).
    var keyScanner = UniqueJSONKeys(bytes)
    let hasUniqueKeys = keyScanner.check()

    guard let document = try? JSONValue.parse(bytes) else { return (.invalid_json, nil) }
    guard devicePanelJSONDepth(document) <= devicePanelDescriptorMaxDepth else {
        return (.invalid_json, nil)
    }
    guard hasUniqueKeys else { return (.duplicate_key, nil) }

    // 4. Root must be an object.
    guard case .object(let root) = document else { return (.schema, nil) }

    // 5. `v` must be the JSON integer token `1`. Foundation erases `1` vs `1.0`,
    //    so the raw member bytes decide; `1.0` and `"1"` are unsupported_version.
    if root["v"] != nil {
        var memberScanner = UniqueJSONKeys(bytes)
        guard let token = memberScanner.rawRootMembers(capturing: ["v"], enforcingUnique: [])?["v"] else {
            return (.invalid_json, nil)
        }
        guard token == Data("1".utf8) else { return (.unsupported_version, nil) }
    }

    // 6. Descriptor schema (closed members; missing `v` is a schema failure).
    guard let parsed = devicePanelParseDescriptor(root) else { return (.schema, nil) }

    // 7. `device_id` is compared verbatim, case-sensitively.
    guard devicePanelScalarEqual(parsed.deviceID, linkDeviceID) else { return (.device_mismatch, nil) }

    // 8. Controls, in descriptor array order; the first failure wins.
    let advertised = devicePanelAdvertisedTools(tools)
    var controls: [DevicePanelControl] = []
    controls.reserveCapacity(parsed.controls.count)
    for control in parsed.controls {
        guard let inputSchema = advertised[control.tool] else { return (.tool_not_advertised, nil) }
        if let preset = control.preset {
            // The preset subset of §4.2 step 8 is wider than §2: it only limits
            // property-schema members to type/enum/minimum/maximum, so presets
            // may call agent_only tools such as `home.http`.
            guard let form = devicePanelRootForm(inputSchema),
                  form.properties.values.allSatisfy(devicePanelPresetPropertySupported) else {
                return (.tool_not_supported, nil)
            }
            guard devicePanelPresetIsValid(preset, form: form) else { return (.preset_invalid, nil) }
            controls.append(DevicePanelControl(
                tool: control.tool, label: control.label, group: control.group, preset: .object(preset)))
        } else {
            guard case .editors = classifyDevicePanelTool(inputSchema: inputSchema) else {
                return (.tool_not_supported, nil)
            }
            controls.append(DevicePanelControl(
                tool: control.tool, label: control.label, group: control.group, preset: nil))
        }
    }

    // 9. Everything passed.
    return (.ok, DevicePanelDescriptor(title: parsed.title, controls: controls))
}

// MARK: - §4.2 step 6: descriptor schema

private func devicePanelParseDescriptor(_ root: [String: JSONValue]) -> DevicePanelParsedDescriptor? {
    guard Set(root.keys).isSubset(of: Set(["v", "device_id", "title", "controls"])),
          case .number(let version)? = root["v"], version == 1,
          case .string(let deviceID)? = root["device_id"],
          devicePanelTextIsValid(deviceID, maxScalars: devicePanelDescriptorMaxNameScalars),
          case .array(let controlValues)? = root["controls"],
          (1...devicePanelDescriptorMaxControls).contains(controlValues.count) else { return nil }

    var title: String?
    if let titleValue = root["title"] {
        guard case .string(let titleText) = titleValue,
              devicePanelTextIsValid(titleText, maxScalars: devicePanelDescriptorMaxTextScalars) else {
            return nil
        }
        title = titleText
    }

    var controls: [DevicePanelParsedControl] = []
    controls.reserveCapacity(controlValues.count)
    for controlValue in controlValues {
        guard case .object(let control) = controlValue,
              Set(control.keys).isSubset(of: Set(["tool", "label", "group", "preset"])),
              case .string(let tool)? = control["tool"],
              devicePanelTextIsValid(tool, maxScalars: devicePanelDescriptorMaxNameScalars),
              case .string(let label)? = control["label"],
              devicePanelTextIsValid(label, maxScalars: devicePanelDescriptorMaxTextScalars) else {
            return nil
        }
        var group: String?
        if let groupValue = control["group"] {
            guard case .string(let groupText) = groupValue,
                  devicePanelTextIsValid(groupText, maxScalars: devicePanelDescriptorMaxTextScalars) else {
                return nil
            }
            group = groupText
        }
        var preset: [String: JSONValue]?
        if let presetValue = control["preset"] {
            guard case .object(let presetObject) = presetValue else { return nil }
            preset = presetObject
        }
        controls.append(DevicePanelParsedControl(tool: tool, label: label, group: group, preset: preset))
    }
    return DevicePanelParsedDescriptor(deviceID: deviceID, title: title, controls: controls)
}

/// Pure text: 1…`maxScalars` Unicode scalar values with no C0 control or DEL.
private func devicePanelTextIsValid(_ text: String, maxScalars: Int) -> Bool {
    let scalars = text.unicodeScalars
    guard !scalars.isEmpty, scalars.count <= maxScalars else { return false }
    return !scalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

// MARK: - §4.2 step 8: preset validation subset

private func devicePanelAdvertisedTools(_ tools: [JSONValue]) -> [String: JSONValue] {
    var advertised: [String: JSONValue] = [:]
    for tool in tools {
        guard case .object(let members) = tool,
              case .string(let name)? = members["name"] else { continue }
        advertised[name] = members["inputSchema"] ?? .null
    }
    return advertised
}

/// §4.2 step 8 accepts a property schema whose members are a subset of
/// {`type`, `enum`, `minimum`, `maximum`}, whose `type` is one of the five
/// listed JSON types, whose `enum` (when present) is an array, and whose bounds
/// appear only on numeric types and are finite. This is deliberately wider than
/// the §2 editor table.
private func devicePanelPresetPropertySupported(_ property: JSONValue) -> Bool {
    guard case .object(let shape) = property,
          Set(shape.keys).isSubset(of: Set(["type", "enum", "minimum", "maximum", "title"])),
          case .string(let kind)? = shape["type"],
          ["boolean", "integer", "number", "string", "object"].contains(kind) else { return false }
    if let enumValue = shape["enum"] {
        guard case .array = enumValue else { return false }
    }
    for boundName in ["minimum", "maximum"] {
        guard let bound = shape[boundName] else { continue }
        guard kind == "integer" || kind == "number" else { return false }
        guard case .number(let boundValue) = bound, boundValue.isFinite else { return false }
    }
    return true
}

private func devicePanelPresetIsValid(
    _ preset: [String: JSONValue],
    form: DevicePanelRootForm
) -> Bool {
    guard Set(preset.keys).isSubset(of: Set(form.properties.keys)),
          form.required.isSubset(of: Set(preset.keys)) else { return false }
    for (name, value) in preset {
        guard let property = form.properties[name],
              devicePanelPresetValueMatches(value, property: property) else { return false }
    }
    return true
}

private func devicePanelPresetValueMatches(_ value: JSONValue, property: JSONValue) -> Bool {
    guard case .object(let shape) = property,
          case .string(let kind)? = shape["type"] else { return false }
    switch kind {
    case "boolean":
        guard case .bool = value else { return false }
    case "integer":
        // Presets accept mathematically integral numbers, including `50.0`
        // (vector `preset_integral_float`), bounded by 2^53 - 1.
        guard case .number(let number) = value, devicePanelIsSafeInteger(number) else { return false }
    case "number":
        guard case .number(let number) = value, number.isFinite else { return false }
    case "string":
        guard case .string = value else { return false }
    case "object":
        guard case .object = value else { return false }
    default:
        return false
    }
    if let enumValue = shape["enum"] {
        guard case .array(let choices) = enumValue,
              choices.contains(where: { devicePanelJSONTypeStrictEqual($0, value) }) else {
            return false
        }
    }
    if let bound = shape["minimum"], case .number(let boundValue) = bound,
       case .number(let number) = value, number < boundValue {
        return false
    }
    if let bound = shape["maximum"], case .number(let boundValue) = bound,
       case .number(let number) = value, number > boundValue {
        return false
    }
    return true
}

/// JSON type-strict equality for `enum` comparison: a boolean never equals a
/// number, `null` equals nothing, strings compare by Unicode code points, and
/// arrays/objects compare element-wise. (Python's reference implementation also
/// separates int from float; JSON itself has only the number type, and no
/// shared vector exercises that difference.)
private func devicePanelJSONTypeStrictEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null):
        return true
    case (.bool(let left), .bool(let right)):
        return left == right
    case (.number(let left), .number(let right)):
        return left == right
    case (.string(let left), .string(let right)):
        return devicePanelScalarEqual(left, right)
    case (.array(let left), .array(let right)):
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { devicePanelJSONTypeStrictEqual($0.0, $0.1) }
    case (.object(let left), .object(let right)):
        guard left.count == right.count else { return false }
        for (key, value) in left {
            guard let other = right[key], devicePanelJSONTypeStrictEqual(value, other) else { return false }
        }
        return true
    default:
        return false
    }
}

// MARK: - §4.2 step 2: container depth

/// Root container is level 1; objects and arrays both count; scalars are 0.
private func devicePanelJSONDepth(_ value: JSONValue) -> Int {
    switch value {
    case .array(let items):
        return 1 + (items.map(devicePanelJSONDepth).max() ?? 0)
    case .object(let members):
        return 1 + (members.values.map(devicePanelJSONDepth).max() ?? 0)
    default:
        return 0
    }
}
