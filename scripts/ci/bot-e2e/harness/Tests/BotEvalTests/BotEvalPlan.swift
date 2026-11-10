// SPDX-License-Identifier: MIT
// phone-dsh Bot eval runner — the normalized plan written by eval_catalog.py.
//
// The Python entry point validates the user catalog against catalog.schema.json
// and writes this plan. The Swift runner re-checks the plan's required fields
// here so a malformed or hand-edited plan cannot turn into a silently empty
// run.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHBot

struct EvalPlan: Decodable {
    var version: Int
    var catalog: String
    var catalogSHA256: String
    var upstream: String
    var repeatCount: Int
    var selftest: Bool
    var keepBodies: Bool
    var fixturesRoot: String
    var results: String
    var batchBudget: EvalBudget
    var scenarios: [EvalScenario]

    enum CodingKeys: String, CodingKey {
        case version, catalog, upstream, repeatCount = "repeat", selftest
        case catalogSHA256 = "catalog_sha256"
        case keepBodies = "keep_bodies"
        case fixturesRoot = "fixtures_root"
        case results
        case batchBudget = "batch_budget"
        case scenarios
    }

    static func load(from url: URL) throws -> EvalPlan {
        let data = try Data(contentsOf: url)
        let plan = try JSONDecoder().decode(EvalPlan.self, from: data)
        guard plan.version == 1 else {
            throw EvalPlanError.invalid("unsupported plan version \(plan.version)")
        }
        guard plan.upstream == "mock" || plan.upstream == "real" else {
            throw EvalPlanError.invalid("unknown upstream \(plan.upstream)")
        }
        guard plan.repeatCount >= 1 else {
            throw EvalPlanError.invalid("repeat must be at least 1")
        }
        guard !plan.scenarios.isEmpty else {
            throw EvalPlanError.invalid("plan has no scenarios")
        }
        var ids = Set<String>()
        for scenario in plan.scenarios {
            guard ids.insert(scenario.id).inserted else {
                throw EvalPlanError.invalid("duplicate scenario id \(scenario.id)")
            }
            guard !scenario.assertions.isEmpty else {
                throw EvalPlanError.invalid("\(scenario.id): no assertions")
            }
            for assertion in scenario.assertions {
                guard Self.knownAssertions.contains(assertion.type) else {
                    throw EvalPlanError.invalid("\(scenario.id): unknown assertion \(assertion.type)")
                }
            }
            for action in scenario.actions {
                guard Self.knownActions.contains(action.type) else {
                    throw EvalPlanError.invalid("\(scenario.id): unknown action \(action.type)")
                }
            }
        }
        return plan
    }

    static let knownActions: Set<String> = [
        "create_bot", "user_message", "ui_action", "approval_policy",
        "advance_clock", "seed_held_item", "restart_worker",
    ]
    static let knownAssertions: Set<String> = [
        "file_exists", "no_file", "file_contains", "file_regex", "file_json_path",
        "workspace_command", "reply_contains", "reply_not_contains",
        "bot_event", "no_bot_event", "tool_called", "no_tool_call",
        "memory_contains", "memory_absent", "approval_count", "echo_requests",
    ]
}

enum EvalPlanError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "bot-eval plan: \(detail)"
        }
    }
}

struct EvalBudget: Decodable {
    var maxMinutes: Int
    var maxModelRequests: Int

    enum CodingKeys: String, CodingKey {
        case maxMinutes = "max_minutes"
        case maxModelRequests = "max_model_requests"
    }
}

struct EvalScenario: Decodable {
    var id: String
    var title: String
    var expect: String
    var skip: String?
    var budget: EvalBudget
    var workspace: EvalWorkspace
    var network: EvalNetwork
    var actions: [EvalAction]
    var assertions: [EvalAssertion]
    var timeoutS: Double
    var mock: EvalMock?

    enum CodingKeys: String, CodingKey {
        case id, title, expect, skip, budget, workspace, network, actions, assertions, mock
        case timeoutS = "timeout_s"
    }
}

struct EvalWorkspace: Decodable {
    var bot: String
    var root: String
    var files: [String: String]
    var fixture: String?

    enum CodingKeys: String, CodingKey { case bot, root, files, fixture }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bot = try container.decodeIfPresent(String.self, forKey: .bot) ?? "main"
        root = try container.decodeIfPresent(String.self, forKey: .root) ?? "bot"
        files = try container.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        fixture = try container.decodeIfPresent(String.self, forKey: .fixture)
    }
}

struct EvalNetwork: Decodable {
    var allow: [String]

    enum CodingKeys: String, CodingKey { case allow }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allow = try container.decodeIfPresent([String].self, forKey: .allow) ?? []
    }
}

struct EvalMock: Decodable {
    var finalText: String?
    var tool: EvalToolCall?
    var tools: [EvalToolCall]?
    var promptRules: [EvalPromptRule]?

    enum CodingKeys: String, CodingKey {
        case finalText = "final_text"
        case tool, tools
        case promptRules = "prompt_rules"
    }
}

struct EvalToolCall: Decodable {
    var name: String
    var arguments: JSONValue
}

struct EvalPromptRule: Decodable {
    var contains: String
    var finalText: String

    enum CodingKeys: String, CodingKey {
        case contains
        case finalText = "final_text"
    }
}

struct EvalApprovalPolicy: Decodable {
    var defaultDecision: String
    var rules: [EvalApprovalRule]
    var bot: String?

    enum CodingKeys: String, CodingKey {
        case defaultDecision = "default"
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultDecision = try container.decodeIfPresent(String.self, forKey: .defaultDecision) ?? "manual"
        rules = try container.decodeIfPresent([EvalApprovalRule].self, forKey: .rules) ?? []
    }

    init(defaultDecision: String, rules: [EvalApprovalRule], bot: String? = nil) {
        self.defaultDecision = defaultDecision
        self.rules = rules
        self.bot = bot
    }
}

struct EvalApprovalRule: Decodable {
    var tool: String?
    var decision: String
}

struct EvalAction: Decodable {
    var type: String
    var index: Int?
    var bot: String?
    var text: String?
    var name: String?
    var description: String?
    var alias: String?
    var kind: String?
    var card: String?
    var cardID: String?
    var option: Int?
    var optionID: String?
    var approval: String?
    var approvalID: String?
    var decision: String?
    var digest: String?
    var factContains: String?
    var factID: String?
    var taskID: String?
    var threadID: String?
    var seconds: Int?
    var title: String?
    var fromAgentID: String?
    var fromAgentName: String?
    var requestID: String?
    var mode: String?
    var perturbation: String?
    var degraded: String?
    var mock: EvalMock?
    var timeoutS: Double?
    var policyDefault: String?
    var policyRules: [EvalApprovalRule]?

    enum CodingKeys: String, CodingKey {
        case type, index, bot, text, name, description, alias, kind, card
        case cardID = "card_id"
        case option
        case optionID = "option_id"
        case approval
        case approvalID = "approval_id"
        case decision, digest
        case factContains = "fact_contains"
        case factID = "fact_id"
        case taskID = "task_id"
        case threadID = "thread_id"
        case seconds
        case title
        case fromAgentID = "from_agent_id"
        case fromAgentName = "from_agent_name"
        case requestID = "request_id"
        case mode, perturbation, degraded, mock
        case timeoutS = "timeout_s"
        case policyDefault = "default"
        case policyRules = "rules"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        index = try container.decodeIfPresent(Int.self, forKey: .index)
        bot = try container.decodeIfPresent(String.self, forKey: .bot)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        card = try container.decodeIfPresent(String.self, forKey: .card)
        cardID = try container.decodeIfPresent(String.self, forKey: .cardID)
        option = try container.decodeIfPresent(Int.self, forKey: .option)
        optionID = try container.decodeIfPresent(String.self, forKey: .optionID)
        approval = try container.decodeIfPresent(String.self, forKey: .approval)
        approvalID = try container.decodeIfPresent(String.self, forKey: .approvalID)
        decision = try container.decodeIfPresent(String.self, forKey: .decision)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        factContains = try container.decodeIfPresent(String.self, forKey: .factContains)
        factID = try container.decodeIfPresent(String.self, forKey: .factID)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        seconds = try container.decodeIfPresent(Int.self, forKey: .seconds)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        fromAgentID = try container.decodeIfPresent(String.self, forKey: .fromAgentID)
        fromAgentName = try container.decodeIfPresent(String.self, forKey: .fromAgentName)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        perturbation = try container.decodeIfPresent(String.self, forKey: .perturbation)
        degraded = try container.decodeIfPresent(String.self, forKey: .degraded)
        mock = try container.decodeIfPresent(EvalMock.self, forKey: .mock)
        timeoutS = try container.decodeIfPresent(Double.self, forKey: .timeoutS)
        policyDefault = try container.decodeIfPresent(String.self, forKey: .policyDefault)
        policyRules = try container.decodeIfPresent([EvalApprovalRule].self, forKey: .policyRules)
    }
}

struct EvalAssertion: Decodable {
    var type: String
    var bot: String?
    var expectOK: Bool
    var value: String?
    var path: String?
    var command: String?
    var timeoutS: Double?
    var turn: Int?
    var event: String?
    var whereFields: [String: JSONValue]?
    var name: String?
    var argumentsContains: String?
    var payloadContains: String?
    var scope: String?
    var tier: String?
    var source: String?
    var method: String?
    var equals: Int?
    var max: Int?

    enum CodingKeys: String, CodingKey {
        case type, bot, value, path, command, turn, event, name, scope, tier, source, method, equals, max
        case expectOK = "expect_ok"
        case timeoutS = "timeout_s"
        case whereFields = "where"
        case argumentsContains = "arguments_contains"
        case payloadContains = "payload_contains"
    }

    init(type: String, bot: String? = nil, expectOK: Bool = true,
         value: String? = nil, path: String? = nil, command: String? = nil,
         timeoutS: Double? = nil, turn: Int? = nil, event: String? = nil,
         whereFields: [String: JSONValue]? = nil, name: String? = nil,
         argumentsContains: String? = nil, payloadContains: String? = nil,
         scope: String? = nil, tier: String? = nil, source: String? = nil,
         method: String? = nil, equals: Int? = nil, max: Int? = nil) {
        self.type = type
        self.bot = bot
        self.expectOK = expectOK
        self.value = value
        self.path = path
        self.command = command
        self.timeoutS = timeoutS
        self.turn = turn
        self.event = event
        self.whereFields = whereFields
        self.name = name
        self.argumentsContains = argumentsContains
        self.payloadContains = payloadContains
        self.scope = scope
        self.tier = tier
        self.source = source
        self.method = method
        self.equals = equals
        self.max = max
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        bot = try container.decodeIfPresent(String.self, forKey: .bot)
        expectOK = try container.decodeIfPresent(Bool.self, forKey: .expectOK) ?? true
        value = try container.decodeIfPresent(String.self, forKey: .value)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        timeoutS = try container.decodeIfPresent(Double.self, forKey: .timeoutS)
        turn = try container.decodeIfPresent(Int.self, forKey: .turn)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        whereFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .whereFields)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        argumentsContains = try container.decodeIfPresent(String.self, forKey: .argumentsContains)
        payloadContains = try container.decodeIfPresent(String.self, forKey: .payloadContains)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        equals = try container.decodeIfPresent(Int.self, forKey: .equals)
        max = try container.decodeIfPresent(Int.self, forKey: .max)
    }
}
