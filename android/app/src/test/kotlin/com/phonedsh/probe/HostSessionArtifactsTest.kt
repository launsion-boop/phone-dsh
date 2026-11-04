// The 本 session 产物 fact: the per-turn workspace measurement, without a device.
// SPDX-License-Identifier: MIT
//
// What this test pins is the lane's central claim: the host can *measure* which
// workspace files a turn wrote, and it never guesses. The three rules a reader
// should be able to check here are the three the page depends on:
//
//  1. a file that appears while a turn is armed is that turn's — reported as a
//     workspace-relative path, which is the row id the artifacts page lists;
//  2. a file that was already there is not ("a scan cannot answer this session's
//     question" is the reason this class exists, not a detail);
//  3. no armed turn means no claim at all — an unmeasured host says nothing rather
//     than attributing the whole workspace to the first turn that ever ran.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class HostSessionArtifactsTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun workspace(): Path = temporary.newFolder("xl", "materialized", "workspace").toPath()

    private fun write(root: Path, relativePath: String, text: String) {
        val file = root.resolve(relativePath)
        Files.createDirectories(file.parent)
        Files.write(file, text.toByteArray())
    }

    private fun toolCall(tool: String, argumentsJson: String): HostEvent = HostEvent(
        kind = HostEventKind.TOOL_CALL,
        seq = 1,
        dshType = "tool/call",
        turnId = "turn-0001",
        data = JsonObject(
            linkedMapOf(
                "name" to JsonString(tool),
                "arguments" to JsonString(argumentsJson),
            ),
        ),
        raw = JsonObject(emptyMap()),
    )

    @Test
    fun `a file written during the turn is that turn's, by workspace-relative path`() {
        val root = workspace()
        val artifacts = HostSessionArtifacts(root)

        artifacts.beginTurn()
        write(root, "orders-summary.md", "# summary\namount total: 325.21\n")
        artifacts.endTurn()

        assertEquals(listOf("orders-summary.md"), artifacts.currentFacts().writtenPaths)
    }

    @Test
    fun `a file that was already there is not attributed to the turn`() {
        val root = workspace()
        // The person imported this before the turn: it is 未归属, not this session's.
        write(root, "orders.csv", "id,amount\n1,325.21\n")
        val artifacts = HostSessionArtifacts(root)

        artifacts.beginTurn()
        write(root, "orders-summary.md", "summary\n")
        artifacts.endTurn()

        assertEquals(listOf("orders-summary.md"), artifacts.currentFacts().writtenPaths)
    }

    @Test
    fun `a changed file counts, and a nested path keeps its sub-directory`() {
        val root = workspace()
        write(root, "notes.md", "one\n")
        val artifacts = HostSessionArtifacts(root)

        artifacts.beginTurn()
        write(root, "notes.md", "two, a longer body\n")
        write(root, "reports/summary.md", "nested\n")
        artifacts.endTurn()

        assertEquals(
            listOf("notes.md", "reports/summary.md"),
            artifacts.currentFacts().writtenPaths,
        )
    }

    @Test
    fun `a turn that never ran claims nothing`() {
        val root = workspace()
        write(root, "before.md", "before\n")
        val artifacts = HostSessionArtifacts(root)

        // endTurn without beginTurn: the first turn of a cold process must not
        // inherit the whole workspace as its output.
        artifacts.endTurn()

        assertEquals(emptyList<String>(), artifacts.currentFacts().writtenPaths ?: emptyList<String>())
        assertTrue(artifacts.currentFacts().writtenPaths == emptyList<String>() ||
            artifacts.currentFacts().writtenPaths == null)
    }

    @Test
    fun `a named write tool's path is accepted and normalized`() {
        val root = workspace()
        val artifacts = HostSessionArtifacts(root)

        artifacts.observe(toolCall("write", "{\"path\":\"/dsh/workspace/reports/out.md\"}"))
        artifacts.observe(toolCall("edit", "{\"file_path\":\"./notes.md\"}"))
        // A read tool names no write, and a path outside the workspace is refused.
        artifacts.observe(toolCall("bash", "{\"command\":\"cat /dsh/workspace/orders.csv\"}"))
        artifacts.observe(toolCall("write", "{\"path\":\"/etc/passwd\"}"))
        artifacts.observe(toolCall("write", "{\"path\":\"/dsh/workspace/../escape.md\"}"))

        assertEquals(listOf("reports/out.md", "notes.md"), artifacts.currentFacts().writtenPaths)
    }

    @Test
    fun `a new conversation clears the attribution`() {
        val root = workspace()
        val artifacts = HostSessionArtifacts(root)
        artifacts.beginTurn()
        write(root, "a.md", "a\n")
        artifacts.endTurn()
        assertEquals(1, artifacts.currentFacts().writtenPaths?.size)

        artifacts.clear()

        assertEquals(emptyList<String>(), artifacts.currentFacts().writtenPaths)
    }

    @Test
    fun `the diff compares size and modification time, not just presence`() {
        val before = mapOf(
            "same.md" to WorkspaceStamp(4, 1_000),
            "gone.md" to WorkspaceStamp(2, 2_000),
        )
        val after = mapOf(
            "same.md" to WorkspaceStamp(4, 2_000),
            "new.md" to WorkspaceStamp(1, 2_000),
        )

        assertEquals(
            listOf("new.md", "same.md"),
            HostSessionArtifacts.addedOrChanged(before, after),
        )
    }
}
