// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHAgentCore

/// device-panel.md §2: the deterministic mapping from one advertised tool's
/// `inputSchema` to panel editors. This is a pure function: no Link access, no
/// UI state, no file I/O.
public enum DevicePanelEditor: Equatable, Sendable {
    case toggle(arg: String, required: Bool)
    case slider(arg: String, required: Bool, integer: Bool, min: Double, max: Double)
    case picker(arg: String, required: Bool, options: [String])
}

public enum DevicePanelRender: Equatable, Sendable {
    case editors([DevicePanelEditor])
    case agentOnly
}

/// The closed root form shared by §2 and §4.2 step 8: the property schemas plus
/// the resolved `required` names. `nil` when the root is not the supported form.
struct DevicePanelRootForm {
    var properties: [String: JSONValue]
    var required: Set<String>
}

let devicePanelMaxProperties = 16
let devicePanelMaxOptions = 32
let devicePanelMaxOptionScalars = 64
let devicePanelMaxTitleScalars = 20
/// 2^53 - 1: the largest integer an IEEE-754 `Double` represents exactly.
/// device-panel.md §2 rejects an integer slider bound whose absolute value
/// exceeds it (including exactly 2^53, vector `integer_bound_beyond_safe`).
let devicePanelMaxSafeInteger: Double = 9_007_199_254_740_991

/// device-panel.md §2: classify one advertised tool's `inputSchema`.
///
/// A tool whose required argument has no supported editor is `agentOnly`; an
/// unsupported optional argument gets no editor and the tool still renders.
/// Required editors come first, then optional ones; each group is ordered by
/// the argument name's Unicode code points, not by the wire object's member order.
public func classifyDevicePanelTool(inputSchema: JSONValue) -> DevicePanelRender {
    guard let form = devicePanelRootForm(inputSchema) else { return .agentOnly }
    var editors: [DevicePanelEditor] = []
    let ordered = form.properties.keys.sorted { lhs, rhs in
        let lhsRequired = form.required.contains(lhs), rhsRequired = form.required.contains(rhs)
        if lhsRequired != rhsRequired { return lhsRequired }
        return devicePanelScalarOrder(lhs, rhs)
    }
    for arg in ordered {
        guard let property = form.properties[arg] else { continue }
        let required = form.required.contains(arg)
        if let editor = devicePanelEditor(arg: arg, property: property, required: required) {
            editors.append(editor)
        } else if required {
            return .agentOnly
        }
    }
    return .editors(editors)
}

/// device-panel.md §2 root form: members ⊆ {`type`, `properties`, `required`,
/// `additionalProperties`}, `type` is `"object"`, `additionalProperties` is
/// `false`, at most 16 properties, and `required` (when present) is a
/// duplicate-free array of property names.
func devicePanelRootForm(_ inputSchema: JSONValue) -> DevicePanelRootForm? {
    guard case .object(let root) = inputSchema,
          Set(root.keys).isSubset(of: Set(["type", "properties", "required", "additionalProperties"])),
          case .string("object")? = root["type"],
          case .bool(false)? = root["additionalProperties"],
          case .object(let properties)? = root["properties"],
          properties.count <= devicePanelMaxProperties else { return nil }
    var required = Set<String>()
    if let requiredValue = root["required"] {
        guard case .array(let names) = requiredValue else { return nil }
        for name in names {
            guard case .string(let text) = name,
                  properties[text] != nil,
                  required.insert(text).inserted else { return nil }
        }
    }
    return DevicePanelRootForm(properties: properties, required: required)
}

/// device-panel.md §2: the display name of every argument that has an editor and
/// a `title`. The request still uses the argument name.
public func devicePanelEditorTitles(inputSchema: JSONValue) -> [String: String] {
    guard let form = devicePanelRootForm(inputSchema) else { return [:] }
    var titles: [String: String] = [:]
    for (arg, property) in form.properties {
        guard devicePanelEditor(arg: arg, property: property, required: form.required.contains(arg)) != nil,
              case .object(let shape) = property, case .string(let title)? = shape["title"] else { continue }
        titles[arg] = title
    }
    return titles
}

/// `title`: 1…20 Unicode scalars with no C0 control or DEL.
func devicePanelTitleIsValid(_ value: JSONValue) -> Bool {
    guard case .string(let title) = value else { return false }
    let scalars = title.unicodeScalars
    return (1...devicePanelMaxTitleScalars).contains(scalars.count)
        && !scalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

/// device-panel.md §2 property → editor. Without its optional, valid `title`,
/// the member set must be exactly one of the four table rows; any extra member
/// (even `description`) is unsupported.
private func devicePanelEditor(
    arg: String,
    property: JSONValue,
    required: Bool
) -> DevicePanelEditor? {
    guard case .object(let shape) = property,
          case .string(let kind)? = shape["type"] else { return nil }
    if let title = shape["title"], !devicePanelTitleIsValid(title) { return nil }
    let members = Set(shape.keys).subtracting(["title"])
    switch kind {
    case "boolean":
        guard members == Set(["type"]) else { return nil }
        return .toggle(arg: arg, required: required)
    case "integer":
        guard members == Set(["type", "minimum", "maximum"]),
              case .number(let minimum)? = shape["minimum"],
              case .number(let maximum)? = shape["maximum"],
              devicePanelIsSafeInteger(minimum),
              devicePanelIsSafeInteger(maximum),
              minimum < maximum else { return nil }
        return .slider(arg: arg, required: required, integer: true, min: minimum, max: maximum)
    case "number":
        guard members == Set(["type", "minimum", "maximum"]),
              case .number(let minimum)? = shape["minimum"],
              case .number(let maximum)? = shape["maximum"],
              minimum.isFinite,
              maximum.isFinite,
              minimum < maximum else { return nil }
        return .slider(arg: arg, required: required, integer: false, min: minimum, max: maximum)
    case "string":
        guard members == Set(["type", "enum"]),
              case .array(let enumValues)? = shape["enum"],
              (1...devicePanelMaxOptions).contains(enumValues.count) else { return nil }
        var options: [String] = []
        for enumValue in enumValues {
            guard case .string(let option) = enumValue,
                  (1...devicePanelMaxOptionScalars).contains(option.unicodeScalars.count) else {
                return nil
            }
            options.append(option)
        }
        guard devicePanelStringsAreDistinct(options) else { return nil }
        return .picker(arg: arg, required: required, options: options)
    default:
        return nil
    }
}

/// §2 integer bounds are integral values whose absolute value is ≤ 2^53 - 1.
/// `Double` has already erased whether the wire token was `1` or `1.0`; for a
/// schema bound both spellings are mathematically integral, unlike `v` in §4.2.
func devicePanelIsSafeInteger(_ value: Double) -> Bool {
    value.isFinite && value.rounded() == value && abs(value) <= devicePanelMaxSafeInteger
}

/// Unicode code point order, as §2 requires for editor sorting. Swift's
/// `String` `<` uses canonical ordering, which would tie canonically equivalent
/// names; comparing scalar values keeps the order deterministic.
func devicePanelScalarOrder(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
}

/// Verbatim (code point) string equality. Swift's `String` `==` treats
/// canonically equivalent sequences as the same string; §4.2 compares
/// `device_id` literally and `enum` values type- and value-strictly.
func devicePanelScalarEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
}

func devicePanelStringsAreDistinct(_ values: [String]) -> Bool {
    for index in values.indices {
        for other in values.indices where other < index {
            if devicePanelScalarEqual(values[index], values[other]) { return false }
        }
    }
    return true
}
