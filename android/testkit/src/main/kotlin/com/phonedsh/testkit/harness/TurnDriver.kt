// :testkit harness — how the third runner "delivers" a turn when there is no model.
// SPDX-License-Identifier: MIT
//
// ---- the honesty rule this file exists for ---------------------------------
// The macOS and iOS runners hand each prompt to a real DeepSeek turn. The
// Android third runner does not: `:net`'s gateway is wired into the host but no
// upstream credential or model loop is attached to this lane, so there is
// nothing that could produce a real assistant turn. The two drivers below say
// exactly that instead of inventing one:
//
//   * [ScriptedTurnDriver] replays *pre-set* [TurnOutcome] values. The turn ends
//     the way the caller scripted; the model is a script, not a model. It never
//     reads the prompt and it never writes the workspace, so a scenario whose
//     assertions depend on model work will fail honestly (the file assertions
//     see only the seeded tree).
//   * [NoModelTurnDriver] reports every planned turn as **not delivered**, which
//     makes the runner's run-completion gate mark every progress-dependent
//     assertion `not executed` instead of inventing a verdict.
//
// A real model needs `:net`'s `GatewaySession` plus a live upstream and the
// engine turn loop that feeds tool calls back into the VFS. That is the next
// step for this lane, not something a driver can fake.

package com.phonedsh.testkit.harness

import com.phonedsh.testkit.scenario.TurnOutcome

/**
 * One way of delivering a scenario turn to the third runner.
 *
 * A driver only reports **how the turn ended**. It cannot write the workspace:
 * the seam this file implements is [TurnOutcome] (delivered? terminal reason?),
 * so an execution cannot smuggle model output into the materialized tree
 * through a driver. Workspace state comes from the real VFS/WAL path and from
 * nothing else.
 */
public fun interface ScenarioTurnDriver {
    /**
     * Reports the observed outcome of the turn at [index] for [prompt].
     *
     * @param prompt the catalog prompt, passed verbatim. A scripted driver may
     *   ignore it; the execution records it regardless.
     * @param index the 0-based scenario-turn index.
     */
    public fun drive(prompt: String, index: Int): TurnOutcome
}

/**
 * A driver that replays pre-set [TurnOutcome] values, in order.
 *
 * **The model is scripted, not real.** This is a test fixture, not a model
 * stand-in: it returns [outcomes]`[index]` (or [fallback] once the list is
 * exhausted) and does nothing else. It is the honest way to exercise the
 * runner's verdict logic on a host — "the turn ended `completed`, so evaluate
 * the assertions against whatever the real workspace holds" — without
 * pretending an assistant produced the workspace.
 *
 * @param outcomes the outcomes for turns 0..n-1, in delivery order.
 * @param fallback returned for every turn past [outcomes]; a clean `completed`
 *   turn by default.
 */
public class ScriptedTurnDriver private constructor(
    private val outcomes: List<TurnOutcome>,
    private val fallback: TurnOutcome,
) : ScenarioTurnDriver {
    public constructor(vararg outcomes: TurnOutcome) : this(outcomes.toList(), TurnOutcome())

    /** Every prompt handed to [drive], in order, so a test can assert delivery. */
    public val prompts: MutableList<String> = mutableListOf()

    override fun drive(prompt: String, index: Int): TurnOutcome {
        prompts += prompt
        return outcomes.getOrElse(index) { fallback }
    }

    public companion object {
        /**
         * A driver whose every turn ends `completed`.
         *
         * Useful when the caller wants the runner to evaluate the file
         * assertions on the *seeded* workspace; it deliberately does not make
         * anything pass that the seed does not already satisfy.
         */
        public fun completed(): ScriptedTurnDriver = ScriptedTurnDriver(TurnOutcome())
    }
}

/**
 * The only honest driver when no model is attached: every turn is undelivered.
 *
 * `delivered = false` is not a product failure — it is the fact that this lane
 * cannot run a model turn yet. [com.phonedsh.testkit.scenario.ScenarioRunner]
 * turns that fact into the run-completion gate, so every progress-dependent
 * assertion is reported `not executed` and the scenario can never pass.
 */
public data object NoModelTurnDriver : ScenarioTurnDriver {
    override fun drive(prompt: String, index: Int): TurnOutcome =
        TurnOutcome(delivered = false, detail = DETAIL)

    /** The one sentence a `not delivered` row carries into the report. */
    public const val DETAIL: String =
        "no model: this lane has no :net gateway session or real upstream, so the " +
            "planned turn was not delivered"
}
