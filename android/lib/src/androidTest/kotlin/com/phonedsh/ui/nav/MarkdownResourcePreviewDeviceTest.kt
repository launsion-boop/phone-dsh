// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.page.WorkspaceFile
import com.phonedsh.ui.surface.preview.PreviewFileSource
import com.phonedsh.ui.surface.preview.PreviewResolution
import com.phonedsh.ui.surface.preview.PreviewTextPage
import com.phonedsh.ui.surface.preview.PreviewUnresolved
import com.phonedsh.ui.surface.preview.WorkspacePreviewSource
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlinx.coroutines.runBlocking

@RunWith(AndroidJUnit4::class)
class MarkdownResourcePreviewDeviceTest {
    @Test
    fun resourceUrisOnlyMapToTheCurrentVerifiedWorkspace() {
        val file = "file:///dsh/workspace/docs/a.png"
        val sandbox = "sandbox:docs/a.png"
        assertEquals(
            MarkdownResourcePreviewTarget.WorkspacePath(file, file),
            markdownResourcePreviewTarget(file, currentWorkerSessionId = "worker-A", hasVerifiedWorkspaceRoot = true),
        )
        assertEquals(
            MarkdownResourcePreviewTarget.WorkspacePath(sandbox, sandbox),
            markdownResourcePreviewTarget(sandbox, currentWorkerSessionId = "worker-A", hasVerifiedWorkspaceRoot = true),
        )

        val session = "dsh-resource://file/session/worker-A/dsh/workspace/docs/a.png"
        assertEquals(
            MarkdownResourcePreviewTarget.WorkspacePath(session, "docs/a.png"),
            markdownResourcePreviewTarget(session, currentWorkerSessionId = "worker-A", hasVerifiedWorkspaceRoot = true),
        )
        assertEquals(
            MarkdownResourcePreviewTarget.Refused(session, MarkdownResourceRefusal.DIFFERENT_SESSION),
            markdownResourcePreviewTarget(session, currentWorkerSessionId = "worker-B", hasVerifiedWorkspaceRoot = true),
        )
        assertEquals(
            MarkdownResourcePreviewTarget.Refused(session, MarkdownResourceRefusal.NO_CURRENT_SESSION),
            markdownResourcePreviewTarget(session, currentWorkerSessionId = null, hasVerifiedWorkspaceRoot = true),
        )
        assertEquals(
            MarkdownResourcePreviewTarget.Refused(session, MarkdownResourceRefusal.NO_VERIFIED_WORKSPACE),
            markdownResourcePreviewTarget(session, currentWorkerSessionId = "worker-A", hasVerifiedWorkspaceRoot = false),
        )
        assertEquals(
            MarkdownResourcePreviewTarget.Refused("dsh-resource://file/absolute/etc/passwd", MarkdownResourceRefusal.ABSOLUTE_RESOURCE),
            markdownResourcePreviewTarget("dsh-resource://file/absolute/etc/passwd", "worker-A", true),
        )
    }

    @Test
    fun mappedResourcePathStillPassesThePreviewSourceContainmentBoundary() {
        val root = Files.createTempDirectory("markdown-resource-preview").toRealPath()
        val docs = Files.createDirectories(root.resolve("docs"))
        Files.write(docs.resolve("image.png"), byteArrayOf(1, 2, 3))
        val source = WorkspacePreviewSource(root)
        val mapped = markdownResourcePreviewTarget(
            "dsh-resource://file/session/worker-A/dsh/workspace/docs/image.png",
            currentWorkerSessionId = "worker-A",
            hasVerifiedWorkspaceRoot = true,
        ) as MarkdownResourcePreviewTarget.WorkspacePath

        val resolved = runBlocking { source.resolve(mapped.previewPath) }
        assertTrue(resolved is PreviewResolution.Resolved)
        assertEquals(root.resolve("docs/image.png"), (resolved as PreviewResolution.Resolved).file)

        val escaped = runBlocking { source.resolve("../outside.png") }
        assertEquals(PreviewUnresolved.REJECTED, (escaped as PreviewResolution.Unresolved).reason)
    }

    @Test
    fun sessionOrWorkspaceSwitchDuringResolutionRefusesTheStaleRoute() = runBlocking {
        val firstRoot = Files.createTempDirectory("markdown-resource-first").toRealPath()
        val secondRoot = Files.createTempDirectory("markdown-resource-second").toRealPath()
        val requested = MarkdownResourceContext("ui-local-A", "worker-A", firstRoot)
        val current = AtomicReference(requested)
        val resolving = CompletableDeferred<Unit>()
        val continueResolve = CompletableDeferred<Unit>()
        val source = object : PreviewFileSource {
            override suspend fun files(): List<WorkspaceFile>? = null

            override suspend fun resolve(relativePath: String): PreviewResolution {
                resolving.complete(Unit)
                continueResolve.await()
                return PreviewResolution.Resolved(relativePath, firstRoot.resolve(relativePath), 1L)
            }

            override suspend fun readPage(file: Path, offset: Long): PreviewTextPage = error("not used")

            override suspend fun looksLikeText(file: Path): Boolean = error("not used")
        }
        val target = MarkdownResourcePreviewTarget.WorkspacePath(
            "dsh-resource://file/session/worker-A/dsh/workspace/docs/image.png",
            "docs/image.png",
        )

        val result = async {
            resolveMarkdownPreviewPath(source, target, requested) { current.get() }
        }
        resolving.await()
        // The local UI id is intentionally independent from the Worker id. A switch
        // while resolve() is suspended must prevent routing a path into the new root.
        current.set(MarkdownResourceContext("ui-local-B", "worker-B", secondRoot))
        continueResolve.complete(Unit)

        assertEquals(
            MarkdownResourcePreviewTarget.Refused(target.sourceIdentity, MarkdownResourceRefusal.DIFFERENT_SESSION),
            result.await(),
        )
    }
}
