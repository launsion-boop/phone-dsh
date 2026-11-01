// :testkit scenario — an in-memory ScenarioExecution for runner tests and demos.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.scenario.memory

import com.phonedsh.testkit.scenario.CommandOutcome
import com.phonedsh.testkit.scenario.PerturbationCoverage
import com.phonedsh.testkit.scenario.ScenarioExecution
import com.phonedsh.testkit.scenario.TurnOutcome

/**
 * A [ScenarioExecution] backed by an in-memory file tree and scripted outcomes.
 *
 * It exists so [com.phonedsh.testkit.scenario.ScenarioRunner] can be exercised
 * without a Worker, a device, an engine or a network: a test seeds the tree the
 * turn callbacks produce, scripts how each turn ends, lists console errors and
 * returns command outcomes. It is also a working reference for a real adapter,
 * because it implements only the six-method seam and never reaches around it.
 *
 * The scripted state is deliberately plain mutable data (`onTurn`, `coverage`,
 * `defaultCommandOutcome`): there is no hidden clock, thread or randomness, so a
 * runner test is deterministic.
 */
public class MemoryScenarioExecution : ScenarioExecution {
    private val files = LinkedHashMap<String, ByteArray>()
    private val consoleErrorLines = mutableListOf<String>()
    private val scriptedTurns = ArrayDeque<TurnOutcome>()
    private val commandOutcomes = LinkedHashMap<String, CommandOutcome>()

    /**
     * Invoked inside [runTurn], after the prompt was recorded and before the
     * scripted [TurnOutcome] is returned. A test uses it to model what the turn
     * wrote into the workspace.
     */
    public var onTurn: ((String, MemoryScenarioExecution) -> Unit)? = null

    /** Returned by [runWorkspaceCommand] for a command with no scripted outcome. */
    public var defaultCommandOutcome: CommandOutcome = CommandOutcome(exitCode = 0)

    /** Returned by [perturbationCoverage]; `null` means "coverage not finalized". */
    public var coverage: PerturbationCoverage? = null

    /** Every prompt delivered, in order. */
    public val prompts: MutableList<String> = mutableListOf()

    /** The workspace exactly as passed to [setupWorkspace], for seeding assertions. */
    public var seededFiles: Map<String, ByteArray> = emptyMap()
        private set

    /**
     * Replaces the workspace with [files] (defensive copies on both sides), the
     * way a real execution materializes a clean workspace per scenario.
     */
    override fun setupWorkspace(files: Map<String, ByteArray>) {
        this.files.clear()
        for ((path, content) in files) {
            this.files[path] = content.copyOf()
        }
        seededFiles = this.files.mapValues { (_, content) -> content.copyOf() }
    }

    override fun runTurn(prompt: String): TurnOutcome {
        prompts += prompt
        onTurn?.invoke(prompt, this)
        return if (scriptedTurns.isEmpty()) TurnOutcome() else scriptedTurns.removeFirst()
    }

    override fun workspaceFiles(): Set<String> = files.keys.toSet()

    override fun readFile(path: String): ByteArray? = files[path]?.copyOf()

    override fun consoleErrors(): List<String> = consoleErrorLines.toList()

    override fun runWorkspaceCommand(command: String): CommandOutcome =
        commandOutcomes[command] ?: defaultCommandOutcome

    override fun perturbationCoverage(): PerturbationCoverage? = coverage

    // ------------------------------------------------------------ scripting

    /** Queues [outcomes] for the next turns, in order; the default is a clean turn. */
    public fun scriptTurns(vararg outcomes: TurnOutcome) {
        scriptedTurns.addAll(outcomes)
    }

    /** Adds or replaces one workspace file from UTF-8 [text]. */
    public fun putFile(path: String, text: String) {
        files[path] = text.toByteArray(Charsets.UTF_8)
    }

    /** Adds or replaces one workspace file from raw [bytes]. */
    public fun putFile(path: String, bytes: ByteArray) {
        files[path] = bytes.copyOf()
    }

    /** Removes a workspace path (a no-op when it is already absent). */
    public fun removeFile(path: String) {
        files.remove(path)
    }

    /** Appends one entry to the console-error stream `no_console_error` reads. */
    public fun addConsoleError(message: String) {
        consoleErrorLines += message
    }

    /** Scripts the outcome of exactly [command]. */
    public fun onCommand(command: String, outcome: CommandOutcome) {
        commandOutcomes[command] = outcome
    }
}
