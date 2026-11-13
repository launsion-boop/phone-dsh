// SPDX-License-Identifier: MIT

// P12: the model-purpose enforcer's pure policy types live in
// `PhoneDSHAgentCore` (PC-20261113-p12-model-purpose-sink §2,
// spec/bot/v1/README.md §2.10) so the gateway can call them without a new
// module edge.
//
// The Bot module keeps its existing external names. The mechanism is a
// `typealias`, not a second declaration and not `@_exported import`: P12
// forbids two same-named types, and re-exporting the whole AgentCore surface
// would widen the Bot module's public API for no reason. Callers written
// against `BotModelPurposeGate` / `BotModelRequest` keep compiling and keep
// resolving to the one type in AgentCore.

import PhoneDSHAgentCore

public typealias BotModelPurpose = PhoneDSHAgentCore.BotModelPurpose
public typealias BotModelPurposeDefaults = PhoneDSHAgentCore.BotModelPurposeDefaults
public typealias BotModelPurposeRow = PhoneDSHAgentCore.BotModelPurposeRow
public typealias BotModelPurposePolicy = PhoneDSHAgentCore.BotModelPurposePolicy
public typealias BotModelTier = PhoneDSHAgentCore.BotModelTier
public typealias BotModelPurposeError = PhoneDSHAgentCore.BotModelPurposeError
public typealias BotModelRequest = PhoneDSHAgentCore.BotModelRequest
public typealias BotModelPurposeGate = PhoneDSHAgentCore.BotModelPurposeGate
