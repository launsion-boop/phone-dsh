// phone-dsh — :app: the 本 session 产物 fact, measured from the turns that ran.
// SPDX-License-Identifier: MIT
//
// ---- why this is a measurement and not a parse ------------------------------
// The artifacts page asks one question: *which workspace files did this session
// write?* Two cheaper answers are wrong, and both were considered before this
// file existed:
//
//  * **A directory scan.** `/dsh/workspace` holds the person's own imports (the
//    chat composer's 添加文件 writes them there), a previous session's leftovers
//    and anything a shell command left behind. A scan cannot say "this session
//    wrote it", which is the page's entire subject — it would turn 未归属 rows
//    into fabricated provenance.
//  * **A transcript parse.** The `tool_call` event names a tool and its arguments.
//    For the one tool that writes almost everything (`bash`) the target path is
//    embedded in shell syntax (`printf … > /dsh/workspace/x.md`, `tee`, `cp`,
//    heredocs), so a regex would both miss writes and invent them. A named write
//    tool (`write`/`edit`/`str_replace_editor`) *does* carry a `path`, and those
//    paths are accepted here as one corroborating signal — but the file still has
//    to exist on disk before a row is drawn, and the path alone is never enough.
//
// So the host measures the filesystem it owns. The materialized workspace
// (`<filesDir>/xl/materialized/workspace`) is written by the WAL as the Worker's
// VFS mutations arrive (the same tree the files page and the preview read), so
// the host can diff it around a turn:
//
//   beginTurn()  — stamp every file (size + modified time) before the prompt goes out
//   endTurn()    — stamp again and record every path that appeared or changed
//
// The turn is the unit because the turn is the only span the host controls: one
// chat turn is in flight at a time (`turnRunning`), and nothing else writes that
// tree while it runs. A path is therefore "this session's" when its bytes changed
// *while one of this session's own turns was running* — a claim the disk can
// support, unlike "it is in the folder".
//
// ---- what it deliberately does not do ---------------------------------------
//  * No persistence: the fact is this process's measurement. After a cold start the
//    host has measured no turn, so it claims nothing and every workspace file is
//    listed as 未归属 (the honest reading of "not measured"), never as the current
//    session's. The listing itself is unaffected — the page still shows the files.
//  * No content reads: the page's source does those. This file only decides
//    authorship.
//  * No clock, no network, no logging of paths: a workspace path can quote what a
//    person typed, so nothing here is printed.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.ui.page.SessionArtifactsFacts
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One file's identity in the diff: its size and its modification time.
 *
 * Both are compared because either alone misses a real write: an edit that keeps
 * the byte count (`x → y`) changes only the time, and a fast rewrite can land in
 * the same millisecond with a different size. A same-size rewrite inside the same
 * millisecond is the one write this pair cannot see, which is why a named write
 * tool's path is accepted as well.
 */
internal data class WorkspaceStamp(val sizeBytes: Long, val modifiedMillis: Long)

/**
 * The per-turn measurement behind [SessionArtifactsFacts].
 *
 * @param workspace the materialized workspace root
 *   (`<filesDir>/xl/materialized/workspace`). The tree may not exist yet — the WAL
 *   creates it on the first write, and a turn that writes nothing leaves it absent.
 */
internal class HostSessionArtifacts(private val workspace: Path) {
    private val written = LinkedHashSet<String>()
    private val mutableFacts = MutableStateFlow(SessionArtifactsFacts())
    private var baseline: Map<String, WorkspaceStamp> = emptyMap()
    private var turnOpen = false

    /** The fact the artifacts page reads; one value per measurement. */
    val facts: StateFlow<SessionArtifactsFacts> = mutableFacts.asStateFlow()

    /**
     * Starts one turn's measurement.
     *
     * Idempotent: a second call while a turn is already open keeps the original
     * baseline, so a retried send cannot launder an earlier write into this turn.
     */
    fun beginTurn() {
        if (turnOpen) return
        baseline = snapshot(workspace)
        turnOpen = true
    }

    /**
     * Ends the turn and records every path the turn changed.
     *
     * Safe to call without a matching [beginTurn] (a turn the host never armed): it
     * then records nothing rather than diffing against an absent baseline, which
     * would attribute every file in the workspace to the first turn that ran.
     */
    fun endTurn() {
        if (!turnOpen) return
        turnOpen = false
        record(addedOrChanged(baseline, snapshot(workspace)))
    }

    /**
     * Reads one Worker event for the corroborating signal: a *named* write tool's
     * path, already normalized to a workspace-relative path.
     *
     * Every other event is ignored here; the bytes are the evidence.
     */
    fun observe(event: HostEvent) {
        if (event.kind != HostEventKind.TOOL_CALL) return
        namedWritePath(event)?.let { path -> record(listOf(path)) }
    }

    /**
     * Forgets every claimed path: a new conversation starts its own session and
     * must not inherit the previous one's attribution.
     */
    fun clear() {
        written.clear()
        baseline = emptyMap()
        turnOpen = false
        publish()
    }

    /** The current fact value (`facts.value` is the same read). */
    fun currentFacts(): SessionArtifactsFacts = mutableFacts.value

    private fun record(paths: Collection<String>) {
        var changed = false
        for (path in paths) {
            if (path.isEmpty()) continue
            if (written.add(path)) changed = true
        }
        if (changed) publish()
    }

    private fun publish() {
        mutableFacts.value = SessionArtifactsFacts(writtenPaths = written.toList())
    }

    /** The `path` argument of a write tool's `tool_call`, workspace-relative. */
    private fun namedWritePath(event: HostEvent): String? {
        val data = event.data ?: return null
        val tool = (data["name"] as? JsonString)?.value ?: return null
        if (tool !in WRITE_TOOLS) return null
        val arguments = argumentsOf(data) ?: return null
        val raw = (arguments["path"] as? JsonString)?.value
            ?: (arguments["file_path"] as? JsonString)?.value
            ?: (arguments["filePath"] as? JsonString)?.value
            ?: return null
        return relativeWorkspacePath(raw)
    }

    private fun argumentsOf(data: JsonObject): JsonObject? =
        when (val raw = data["arguments"] ?: data["input"]) {
            is JsonObject -> raw
            is JsonString -> runCatching { JsonValue.parse(raw.value) as? JsonObject }.getOrNull()
            else -> null
        }

    /**
     * [raw] as a workspace-relative POSIX path, or `null` when it names a path
     * outside the workspace (the artifacts page only ever lists this tree).
     */
    private fun relativeWorkspacePath(raw: String): String? {
        val path = raw.trim()
        if (path.isEmpty()) return null
        val relative = when {
            path.startsWith(WORKSPACE_MOUNT) -> path.removePrefix(WORKSPACE_MOUNT)
            path == WORKSPACE_ROOT -> return null
            path.startsWith(WORKSPACE_ROOT_SLASH) -> path.removePrefix(WORKSPACE_ROOT_SLASH)
            path.startsWith("/") -> return null
            else -> path.removePrefix("./")
        }
        if (relative.isEmpty()) return null
        if (relative.split('/').any { it == PARENT || it.isEmpty() }) return null
        return relative
    }

    internal companion object {
        /** The Worker's mount path; a tool quotes workspace paths under it. */
        const val WORKSPACE_ROOT: String = "/dsh/workspace"
        const val WORKSPACE_MOUNT: String = "$WORKSPACE_ROOT/"
        private const val WORKSPACE_ROOT_SLASH: String = WORKSPACE_MOUNT
        private const val PARENT: String = ".."

        /** The tool names §2 folds into the changed-files card: they name a path. */
        val WRITE_TOOLS: Set<String> = setOf("write", "edit", "str_replace_editor")

        /** How deep the stamping walk goes; the same bound the files listing uses. */
        const val MAX_DEPTH: Int = 8

        /** How many files one stamp records; beyond this the workspace is not small. */
        const val MAX_ENTRIES: Int = 2_000

        /**
         * Every regular file under [root], as `relativePath -> stamp`.
         *
         * A missing root and an unreadable sub-directory are both "nothing to
         * stamp": the measurement must never fail a turn, and an empty map is the
         * truth for a tree that is not there yet.
         */
        fun snapshot(root: Path): Map<String, WorkspaceStamp> {
            if (!Files.isDirectory(root)) return emptyMap()
            val found = LinkedHashMap<String, WorkspaceStamp>()
            try {
                Files.walkFileTree(
                    root,
                    emptySet(),
                    MAX_DEPTH,
                    object : SimpleFileVisitor<Path>() {
                        override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                            if (!attrs.isRegularFile || attrs.isSymbolicLink) return FileVisitResult.CONTINUE
                            if (found.size >= MAX_ENTRIES) return FileVisitResult.TERMINATE
                            val relative = root.relativize(file).toString().replace('\\', '/')
                            found[relative] = WorkspaceStamp(
                                sizeBytes = attrs.size(),
                                modifiedMillis = attrs.lastModifiedTime().toMillis(),
                            )
                            return FileVisitResult.CONTINUE
                        }

                        override fun visitFileFailed(file: Path, error: IOException): FileVisitResult =
                            FileVisitResult.CONTINUE
                    },
                )
            } catch (_: IOException) {
                // A walk that failed half-way is not a measurement: report none
                // rather than a truncated tree the caller would diff against.
                return emptyMap()
            }
            return found
        }

        /**
         * The paths that appeared or changed between two snapshots, in stable
         * path order. Files.walkFileTree has no cross-platform visitation order.
         * Named tool events still retain their observed insertion order.
         */
        fun addedOrChanged(
            before: Map<String, WorkspaceStamp>,
            after: Map<String, WorkspaceStamp>,
        ): List<String> = after.entries
            .filter { (path, stamp) -> before[path] != stamp }
            .map { it.key }
            .sorted()

    }
}
