// :testkit scenario — the caller-provided execution seam under the pure runner.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario

/**
 * Everything [ScenarioRunner] is allowed to touch of a real (or fake) run.
 *
 * This is the Android third runner's analog of the Swift runner's live host:
 * the runner itself owns no Worker, no WKWebView, no `Process` and no device,
 * so the same `catalog.json` can be evaluated on a plain JVM, in an
 * instrumented test, or (later) against a real on-device host. The
 * implementation decides *how* a fact is observed; the runner decides only
 * whether the catalog assertion holds.
 *
 * The six methods are the whole normative surface. [perturbationCoverage] is
 * the one additional report: `restart_recovered` cannot be derived from a file
 * tree, and the Swift runner evaluates it from the finalized
 * `ScenarioPerturbationCoverage.Verdict`; this default keeps that verdict
 * unfinalized (and therefore fail-loud) for an execution that does not drive
 * perturbations at all.
 */
public interface ScenarioExecution {
    /**
     * Materializes a clean workspace from [files] (`relative path -> bytes`).
     *
     * The map is the fixture payload (when the scenario names one) overlaid
     * with `workspace.files`; values are UTF-8 bytes of the catalog strings,
     * and fixture payloads are copied byte for byte.
     *
     * The seam carries bytes only: file modes, and a fixture's deterministic git
     * history (which the Swift runner builds host-side), are the caller's
     * responsibility when it materializes the tree. A fixture payload that
     * already contains `.git/` (the simulator staging shape) is copied with it.
     */
    public fun setupWorkspace(files: Map<String, ByteArray>)

    /**
     * Delivers one ordinary user turn and reports how it ended.
     *
     * A caller that cannot deliver the turn returns [TurnOutcome] with
     * `delivered = false`; a turn that ran but ended `failed`, `cancelled` or
     * `budget_exhausted` returns that terminal reason. Both make the run
     * incomplete and gate the progress-dependent assertions exactly as
     * `ScenarioRunCompletion.evaluate` does on macOS.
     */
    public fun runTurn(prompt: String): TurnOutcome

    /**
     * The file paths currently materialized in the workspace, relative with
     * `/` separators. This is the direct read behind `file_exists`/`no_file`.
     */
    public fun workspaceFiles(): Set<String>

    /** The bytes of one materialized file, or `null` when the path is absent. */
    public fun readFile(path: String): ByteArray?

    /**
     * The Worker/session console-error stream: one entry per error-level
     * console line or host error event. This is the single source of truth for
     * `no_console_error`, never mixed with runner lifecycle diagnostics.
     */
    public fun consoleErrors(): List<String>

    /**
     * Runs one `workspace_command` command against the materialized workspace.
     *
     * The Swift runner runs it through `/bin/bash` in a throwaway copy, with
     * `/dsh/workspace` rewritten to that copy, and passes on exit 0. On an
     * Android device there is no `/bin/bash`; an execution that cannot spawn
     * returns [CommandOutcome.status] = [CommandStatus.PENDING_HOST] and the
     * assertion is reported as pending, never as a pass (the same two-phase
     * rule as the iOS Simulator).
     */
    public fun runWorkspaceCommand(command: String): CommandOutcome

    /**
     * The finalized perturbation-coverage verdict, or `null` when it was never
     * finalized. `null` makes `restart_recovered` fail loud, never pass
     * vacuously.
     */
    public fun perturbationCoverage(): PerturbationCoverage? = null
}

/**
 * The observed outcome of one delivered turn.
 *
 * [terminalReason] mirrors the DSH `turn/ended` reasons the Swift runner maps
 * to `terminal_reason`: `completed` is the only value a completed run accepts.
 */
public data class TurnOutcome(
    /** `false` means the runner never delivered this planned turn. */
    public val delivered: Boolean = true,
    /** The `turn/ended` reason; [COMPLETED] is the only success value. */
    public val terminalReason: String = COMPLETED,
    /** Optional human-readable detail for diagnostics; not part of the verdict. */
    public val detail: String? = null,
) {
    public companion object {
        /** The only terminal reason a completed run accepts. */
        public const val COMPLETED: String = "completed"
    }
}

/**
 * How a `workspace_command` outcome was produced.
 *
 * [EVALUATED] means a real process ran and [CommandOutcome.exitCode] is its
 * verdict. [PENDING_HOST] is the iOS-Simulator/Android-device deferral: the
 * test process cannot spawn `/bin/bash`, so the command is recorded for a host
 * phase and is **not** a pass.
 */
public enum class CommandStatus {
    EVALUATED,
    PENDING_HOST,
}

/**
 * The observed outcome of one `workspace_command`.
 *
 * [detail], when set, is used verbatim as the assertion detail (the Swift host
 * phase uses it for the `[environment: host-bash; ...]` banner). When absent the
 * runner derives `exit <code>` itself.
 */
public data class CommandOutcome(
    public val exitCode: Int,
    public val stdout: String = "",
    public val timedOut: Boolean = false,
    public val status: CommandStatus = CommandStatus.EVALUATED,
    public val detail: String? = null,
) {
    public companion object {
        /** The deferral an execution returns when it cannot spawn a shell. */
        public fun pendingHost(detail: String): CommandOutcome = CommandOutcome(
            exitCode = -1,
            status = CommandStatus.PENDING_HOST,
            detail = detail,
        )
    }
}

/**
 * The finalized `restart_recovered` verdict (the port of
 * `ScenarioPerturbationCoverage.Verdict`).
 *
 * [ok] is `true` only when every declared perturbation point was reached and
 * recovered with the acked materialized files unchanged. [detail] is written to
 * the assertion result verbatim, so a failure names the point that did not
 * recover.
 */
public data class PerturbationCoverage(
    public val ok: Boolean,
    public val detail: String,
)
