// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: scenario-declared resource
// budgets.
//
// Root cause (G2-FIX-115): the catalog-driven runner built every
// `PhoneDSHHost` with the landed host's default budgets, so a scenario whose
// premise depends on a non-default limit (a forced `EFBIG`, a quota
// exhaustion) silently measured the wrong machine. A declaration in the
// catalog is now the single source for that scenario's resource premise:
// `ScenarioRun` injects it into the host configuration and verifies the
// Worker-reported effective value after boot; a mismatch fails the run loud
// and writes both numbers to `report.json`. No scenario id, prompt or file
// name is compiled into this file.
//
// The declaration is also the single source for the figures a prompt, rubric
// or assertion quotes: `{{budgets.<name>}}` references are expanded at catalog
// load time from the same block. A reference without a declaration, an unknown
// reference, or an unknown/out-of-range declaration key fails the load loudly
// instead of becoming a silently ignored misspelling.

import Foundation
import PhoneDSHController

/// One scenario's optional catalog `budgets` block.
///
/// The block is an object (`"budgets": {"singleFileBytes": 16777216}`), is
/// strictly decoded (unknown keys fail), and validates its values against the
/// host contract range. Absent or `nil` keeps the host's tier default; the
/// runner never changes the host defaults themselves.
public struct ScenarioBudgets: Decodable, Sendable, Equatable {
    /// Declared single-file cap in bytes. The host accepts
    /// ``BudgetTable/minimumSingleFileLimitBytes``...
    /// ``BudgetTable/absoluteMaximumSingleFileBytes`` (16 MiB ... 128 MiB).
    public var singleFileBytes: Int?

    public init(singleFileBytes: Int? = nil) {
        self.singleFileBytes = singleFileBytes
    }

    /// The union of the keys the catalog schema accepts today.
    static let allowedKeys: Set<String> = ["singleFileBytes"]

    private enum CodingKeys: String, CodingKey {
        case singleFileBytes
    }

    /// Accepts every key so an unknown key is reported by name instead of
    /// silently dropped by the synthesized decoder (the G2-FIX-51 discipline).
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(intValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyKey.self)
        let unknown = dynamic.allKeys.map(\.stringValue)
            .filter { !Self.allowedKeys.contains($0) }
            .sorted()
        if let key = unknown.first {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown budgets key \"\(key)\"; allowed keys: "
                    + Self.allowedKeys.sorted().joined(separator: ", ")))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decodeIfPresent(Int.self, forKey: .singleFileBytes)
        if let value {
            let floor = BudgetTable.minimumSingleFileLimitBytes
            let ceiling = BudgetTable.absoluteMaximumSingleFileBytes
            guard value >= floor, value <= ceiling else {
                throw DecodingError.dataCorruptedError(
                    forKey: .singleFileBytes, in: container,
                    debugDescription: "singleFileBytes=\(value) is outside the "
                        + "supported range \(floor)...\(ceiling) bytes (16...128 MiB); "
                        + "the host clamps or rejects out-of-range declarations")
            }
        }
        self.singleFileBytes = value
    }
}

// MARK: - Declared figures in prompts, rubrics and assertions

/// Expands `{{budgets.<name>}}` references from one scenario's declaration.
///
/// Only the explicit `budgets.` namespace is substituted, so catalog payloads
/// that legitimately carry `{{name}}` placeholders (a mail-merge fixture, for
/// example) are never touched. References are resolved once at catalog load;
/// every later consumer (the prompt sent over the harness, the assertion
/// evaluator, the simulator host phase reading `pending_host` commands) sees
/// the same concrete figure.
enum ScenarioBudgetPlaceholders {
    /// The `{{budgets.name}}` reference grammar.
    static let pattern = #"\{\{budgets\.([A-Za-z][A-Za-z0-9]*)\}\}"#

    /// The figures a declaration exposes to the catalog.
    static func values(for budgets: ScenarioBudgets) -> [String: String] {
        guard let bytes = budgets.singleFileBytes else { return [:] }
        var values: [String: String] = [
            "singleFileBytes": String(bytes),
            "singleFileBytesGrouped": grouped(bytes),
        ]
        if bytes % mebibyte == 0 {
            values["singleFileMiB"] = String(bytes / mebibyte)
        }
        return values
    }

    /// Every reference name the schema knows, including the ones a particular
    /// declaration cannot render (non-MiB values have no `singleFileMiB`).
    static let knownReferences: Set<String> = [
        "singleFileBytes", "singleFileBytesGrouped", "singleFileMiB",
    ]

    private static let mebibyte = 1024 * 1024

    /// Expands every reference in `text`. `label` names the location in the
    /// catalog for the fail-loud message.
    static func expand(_ text: String,
                       budgets: ScenarioBudgets?,
                       label: String) throws -> String {
        guard text.contains("{{budgets.") else { return text }
        guard let budgets, budgets.singleFileBytes != nil else {
            throw ScenarioError.environment(
                "\(label) references a {{budgets.*}} figure but the scenario has "
                    + "no budgets.singleFileBytes declaration")
        }
        let values = values(for: budgets)
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            throw ScenarioError.environment(
                "internal error: the budgets reference grammar does not compile: \(error)")
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0,
                                                             length: source.length))
        guard !matches.isEmpty else {
            throw ScenarioError.environment(
                "\(label): malformed budget reference; expected "
                    + "{{budgets.<name>}}; known references: "
                    + knownReferences.sorted().joined(separator: ", "))
        }
        var expanded = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let whole = Range(match.range(at: 0), in: expanded),
                  let nameRange = Range(match.range(at: 1), in: expanded) else {
                continue
            }
            let name = String(expanded[nameRange])
            guard knownReferences.contains(name) else {
                throw ScenarioError.environment(
                    "\(label): unknown budget reference \"{{budgets.\(name)}}\"; "
                        + "known references: "
                        + knownReferences.sorted().joined(separator: ", "))
            }
            guard let value = values[name] else {
                throw ScenarioError.environment(
                    "\(label): {{budgets.\(name)}} is unavailable: singleFileBytes="
                        + "\(budgets.singleFileBytes ?? 0) is not a whole number of MiB")
            }
            expanded.replaceSubrange(whole, with: value)
        }
        if expanded.contains("{{budgets.") {
            throw ScenarioError.environment(
                "\(label): unresolved budget reference; expected "
                    + "{{budgets.<name>}}; known references: "
                    + knownReferences.sorted().joined(separator: ", "))
        }
        return expanded
    }

    /// `16777216` -> `16,777,216`, independent of the process locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value)
        var out = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }
}

// MARK: - Premise provenance

/// The declared-versus-effective resource-budget record written to
/// `report.json` under `budgets`.
///
/// The record is written once the runner has built the host configuration
/// for a scenario that declares a budget, so a reader can see the premise the
/// run was built for and the value the machine actually reported (present on
/// drift and on a missing manifest, with `effectiveSingleFileBytes` absent for
/// the stages that never produced it).
public struct ScenarioBudgetProvenance: Encodable, Equatable, Sendable {
    /// The value the catalog declared.
    public var declaredSingleFileBytes: Int
    /// The limit the host configuration actually resolved to (the public
    /// `PhoneDSHConfiguration.singleFileLimitBytes` after tier gating).
    public var hostConfigurationSingleFileBytes: Int?
    /// `limits.single_file_bytes` from the Worker-published manifest.
    public var effectiveSingleFileBytes: Int?
    /// Where the effective value came from, or the stage that failed.
    public var source: String
    /// `true` only when every observed value equals the declaration.
    public var matches: Bool
    /// Extra detail for a missing or unreadable manifest.
    public var detail: String?

    public init(declaredSingleFileBytes: Int,
                hostConfigurationSingleFileBytes: Int? = nil,
                effectiveSingleFileBytes: Int? = nil,
                source: String,
                matches: Bool,
                detail: String? = nil) {
        self.declaredSingleFileBytes = declaredSingleFileBytes
        self.hostConfigurationSingleFileBytes = hostConfigurationSingleFileBytes
        self.effectiveSingleFileBytes = effectiveSingleFileBytes
        self.source = source
        self.matches = matches
        self.detail = detail
    }

    /// The machine-readable `report.json` shape (snake_case like the rest of
    /// the report document).
    private enum CodingKeys: String, CodingKey {
        case source, matches, detail
        case declaredSingleFileBytes = "declared_single_file_bytes"
        case hostConfigurationSingleFileBytes = "host_configuration_single_file_bytes"
        case effectiveSingleFileBytes = "effective_single_file_bytes"
    }
}

/// Reads and checks the effective single-file budget.
enum ScenarioBudgetCheck {
    /// The Worker-published manifest path below the host workspace root.
    static let capabilitiesRelativePath = "materialized/home/capabilities.json"

    /// Builds a provenance record. `matches` is true only when every value the
    /// run observed equals the declaration.
    static func inspect(declaredSingleFileBytes: Int,
                        hostConfigurationSingleFileBytes: Int?,
                        effectiveSingleFileBytes: Int?,
                        source: String,
                        detail: String? = nil) -> ScenarioBudgetProvenance {
        let matches = hostConfigurationSingleFileBytes == declaredSingleFileBytes
            && effectiveSingleFileBytes == declaredSingleFileBytes
        return ScenarioBudgetProvenance(
            declaredSingleFileBytes: declaredSingleFileBytes,
            hostConfigurationSingleFileBytes: hostConfigurationSingleFileBytes,
            effectiveSingleFileBytes: effectiveSingleFileBytes,
            source: source,
            matches: matches,
            detail: detail)
    }

    /// Checks the host configuration the runner is about to boot. This catches
    /// a declared value the host's tier gate clamped before any Worker runs.
    static func validateHostConfiguration(_ provenance: ScenarioBudgetProvenance) throws {
        guard let configured = provenance.hostConfigurationSingleFileBytes else { return }
        guard configured == provenance.declaredSingleFileBytes else {
            throw ScenarioError.budget(
                "scenario resource budget drift: declared singleFileBytes="
                    + "\(provenance.declaredSingleFileBytes) but the host configuration "
                    + "resolved to singleFileBytes=\(configured); the scenario premise "
                    + "would never take effect")
        }
    }

    /// Checks the effective limit the Worker reported after boot and fails loud
    /// with both numbers when it differs from the declaration.
    static func validateEffective(_ provenance: ScenarioBudgetProvenance) throws {
        try validateHostConfiguration(provenance)
        guard let effective = provenance.effectiveSingleFileBytes else {
            throw ScenarioError.environment(
                "scenario resource budget cannot be verified: declared singleFileBytes="
                    + "\(provenance.declaredSingleFileBytes) but no effective value was "
                    + "reported in \(provenance.source)"
                    + (provenance.detail.map { " (\($0))" } ?? ""))
        }
        guard effective == provenance.declaredSingleFileBytes else {
            throw ScenarioError.budget(
                "scenario resource budget drift: declared singleFileBytes="
                    + "\(provenance.declaredSingleFileBytes) but the Worker reports "
                    + "effective singleFileBytes=\(effective) in \(provenance.source); "
                    + "the scenario premise would never take effect")
        }
    }

    /// Reads `limits.single_file_bytes` from a capability-manifest document.
    ///
    /// The manifest is the Worker's machine-readable report of the environment
    /// it actually booted with (`/dsh/home/capabilities.json`, ENG-05). The
    /// host HELLO caps are capability names only (channel.md §2.2), so this
    /// document is the effective-limit report the runner can verify.
    static func effectiveSingleFileBytes(inCapabilityManifest data: Data) throws -> Int {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ScenarioError.artifact(
                "cannot parse the Worker capability manifest: \(error)")
        }
        guard let document = root as? [String: Any] else {
            throw ScenarioError.artifact(
                "the Worker capability manifest is not a JSON object")
        }
        guard let limits = document["limits"] as? [String: Any] else {
            throw ScenarioError.artifact(
                "the Worker capability manifest has no limits object")
        }
        guard let raw = limits["single_file_bytes"], !(raw is Bool),
              let number = raw as? NSNumber else {
            throw ScenarioError.artifact(
                "the Worker capability manifest has no integer "
                    + "limits.single_file_bytes")
        }
        let value = number.intValue
        guard value > 0, number.doubleValue == Double(value) else {
            throw ScenarioError.artifact(
                "the Worker capability manifest reports an invalid "
                    + "limits.single_file_bytes=\(number)")
        }
        return value
    }
}
