// phone-dsh — :dsh / com.phonedsh.dsh.exec: the exec/1 capability and its tool set.
// SPDX-License-Identifier: MIT
//
// channel.md §4.1: exec/1 says "EXEC_REQ is dispatched and answered with
// EXEC_EVT". A host that has no executable accelerator cannot honestly say that,
// so this file makes "zero tools, still advertise exec/1" unrepresentable:
//
//   * [ToolSet] has no empty value. Its factory is `of(first, ...)`, so a
//     zero-tool set does not compile; [ToolSet.from] answers null for an empty
//     collection instead of inventing one.
//   * [ExecCapability.Available] has a private constructor and is only reachable
//     through those non-empty factories; [ExecCapability.Unavailable] is the
//     zero-tool value, and it contributes no capability string at all.
//   * [ExecBridge]'s constructor takes `ExecCapability.Available`, so a bridge
//     without a tool cannot be built either.
//
// The wire strings live here and nowhere else: exec/1 and one
// `accelerator:<name>` per executable tool, which is exactly the set D12 lets the
// Worker route as 0x20. The host wiring merges them into HostCapabilities; this
// file does not reach into the host package, which is another lane's territory.

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.tools.RegisteredTool

/**
 * A non-empty set of executable accelerators.
 *
 * The public factory demands the first tool as a separate argument, so
 * `ToolSet.of()` is a compile error. [from] is the dynamic-collection form and
 * returns null for an empty collection, because "no tool" is not a tool set.
 *
 * Only the six accelerator names of exec.md §3 are accepted: a `write` handler
 * registered in the same registry is not an accelerator and must never be
 * advertised as one.
 */
class ToolSet private constructor(
    /** The mandatory first tool; its existence is the type-level non-emptiness. */
    val first: RegisteredTool,
    private val rest: List<RegisteredTool>,
) {
    /** Every tool in registration order. */
    val all: List<RegisteredTool> = listOf(first) + rest

    /** Distinct accelerator names in registration order; this is what is advertised. */
    val names: List<String> = all.map { it.name }.distinct()

    init {
        for (tool in all) {
            require(tool.name in ACCELERATORS) {
                "exec/1 may only advertise an accelerator of exec.md §3; " +
                    "\"${tool.name}\" is not one of ${ACCELERATORS.sorted()}"
            }
        }
    }

    companion object {
        /**
         * The accelerator vocabulary of exec.md §3 and channel.md §4.1.
         *
         * `ssh` / `scp` / `adb` are the optional native accelerators of
         * PC-20261105-native-ssh-adb: they never write a local materialized
         * mount, but an SSH command or an SCP upload may change the remote
         * server (exec.md §3). A name here is only *allowed*; it is advertised
         * when a tool is actually registered under it.
         */
        val ACCELERATORS: Set<String> =
            setOf("rg", "jaq", "ts-parse", "ts-query", "phone", "ctx", "ssh", "scp", "adb")

        /**
         * A tool set with at least one member.
         *
         * This signature is the compile-time half of the honesty rule: the first
         * tool is not optional, so an empty set cannot be written.
         */
        fun of(first: RegisteredTool, vararg rest: RegisteredTool): ToolSet =
            ToolSet(first, rest.toList())

        /** The dynamic form; null when [tools] is empty. */
        fun from(tools: Collection<RegisteredTool>): ToolSet? {
            val iterator = tools.iterator()
            if (!iterator.hasNext()) return null
            val first = iterator.next()
            val rest = ArrayList<RegisteredTool>()
            while (iterator.hasNext()) rest.add(iterator.next())
            return ToolSet(first, rest)
        }
    }
}

/**
 * What this lane can contribute to the host HELLO caps (channel.md §4.1).
 *
 * [Unavailable] is the honest zero-tool state: [caps] is empty and [helloCaps]
 * returns the caller's set unchanged, so no code path in this file can append
 * `exec/1` to a HELLO without at least one executable tool.
 */
sealed interface ExecCapability {
    /**
     * The capability strings this lane contributes: `exec/1` plus one
     * `accelerator:<name>` per executable tool for [Available], empty for
     * [Unavailable].
     */
    fun caps(): Set<String>

    /**
     * [base] plus [caps]. The one function host wiring needs:
     * `HostCapabilities(base + capability.helloCaps(emptySet()))`.
     */
    fun helloCaps(base: Set<String>): Set<String>

    /** At least one accelerator exists and can run. */
    class Available private constructor(val tools: ToolSet) : ExecCapability {
        /** Advertised accelerator names; never empty. */
        val names: List<String> get() = tools.names

        override fun caps(): Set<String> = buildSet {
            add(EXEC)
            for (name in tools.names) add(ACCELERATOR_PREFIX + name)
        }

        override fun helloCaps(base: Set<String>): Set<String> = base + caps()

        override fun toString(): String = "Available(${names.joinToString(",")})"

        companion object {
            /** The only constructor: the tool set is already non-empty. */
            internal fun of(tools: ToolSet): Available = Available(tools)
        }
    }

    /** No executable tool exists; this lane contributes nothing. */
    data object Unavailable : ExecCapability {
        override fun caps(): Set<String> = emptySet()

        override fun helloCaps(base: Set<String>): Set<String> = base
    }

    companion object {
        /** `channel.md` §4.1 prefix of a read-only accelerator capability. */
        const val ACCELERATOR_PREFIX: String = "accelerator:"

        /** The one capability this lane owns; intentionally not exposed as a bare constant. */
        private const val EXEC: String = "exec/1"

        /**
         * A capability with at least one tool (compile-time non-empty).
         *
         * The returned value is the only thing [ExecBridge] accepts, so the
         * bridge and the advertised capability always describe the same tools.
         */
        fun of(first: RegisteredTool, vararg rest: RegisteredTool): Available =
            Available.of(ToolSet.of(first, *rest))

        /**
         * The dynamic form used by wiring that builds a registry at runtime.
         *
         * An empty registry answers [Unavailable], never an empty [Available].
         */
        fun from(tools: Collection<RegisteredTool>): ExecCapability =
            ToolSet.from(tools)?.let { Available.of(it) } ?: Unavailable
    }
}
