// Host contract 1 — the harness event stream type.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * The host contract's cold event stream, re-exported from kotlinx.coroutines.
 *
 * `spec/host/v1` defines `events(sessionId, afterSeq)` as a `Flow<HarnessEvent>`.
 * `:core` declares `org.jetbrains.kotlinx:kotlinx-coroutines-core` as an `api`
 * dependency, so this is the real library type under the package the host
 * contract already imports — there is no second Flow implementation here.
 *
 * Consumers collect with the regular coroutines operators and cancellation;
 * see [AgentHarness.events] for the stream's resume and transport-loss rules.
 */
public typealias Flow<T> = kotlinx.coroutines.flow.Flow<T>

/** The consumer side of [Flow]; the real `kotlinx.coroutines.flow.FlowCollector`. */
public typealias FlowCollector<T> = kotlinx.coroutines.flow.FlowCollector<T>
