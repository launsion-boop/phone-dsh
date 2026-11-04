// The narrow markdown-resource-to-preview boundary owned by ChatRoute.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.surface.MarkdownLinkTarget
import com.phonedsh.ui.surface.markdownLinkTarget
import com.phonedsh.ui.surface.preview.PreviewFileSource
import com.phonedsh.ui.surface.preview.PreviewResolution
import com.phonedsh.ui.surface.preview.PreviewUnresolved
import java.net.URI
import java.nio.file.Path
import kotlinx.coroutines.CancellationException

internal enum class MarkdownResourceRefusal {
    INVALID,
    ABSOLUTE_RESOURCE,
    UNSAFE_PATH,
    MISSING_PATH,
    NO_CURRENT_SESSION,
    DIFFERENT_SESSION,
    NO_VERIFIED_WORKSPACE,
}

internal sealed interface MarkdownResourcePreviewTarget {
    /** [sourceIdentity] stays intact until the host's selected workspace is resolved. */
    data class WorkspacePath(val sourceIdentity: String, val previewPath: String) : MarkdownResourcePreviewTarget
    data class Refused(val sourceIdentity: String, val reason: MarkdownResourceRefusal) : MarkdownResourcePreviewTarget
}

/** Identity snapshot captured when a resource link is clicked. */
internal data class MarkdownResourceContext(
    val localSessionId: String?,
    val workerSessionId: String?,
    val workspaceRoot: Path?,
)

/**
 * Resolves one selected resource, then rechecks the session/root snapshot before the caller can
 * navigate. A source switch while PreviewFileSource is on IO therefore never routes the resolved
 * relative path through a different session's workspace.
 */
internal suspend fun resolveMarkdownPreviewPath(
    source: PreviewFileSource,
    target: MarkdownResourcePreviewTarget.WorkspacePath,
    requestedContext: MarkdownResourceContext,
    currentContext: () -> MarkdownResourceContext,
): MarkdownResourcePreviewTarget {
    val resolution = try {
        source.resolve(target.previewPath)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        return MarkdownResourcePreviewTarget.Refused(target.sourceIdentity, MarkdownResourceRefusal.MISSING_PATH)
    }
    if (currentContext() != requestedContext) {
        return MarkdownResourcePreviewTarget.Refused(target.sourceIdentity, MarkdownResourceRefusal.DIFFERENT_SESSION)
    }
    return when (resolution) {
        is PreviewResolution.Resolved -> MarkdownResourcePreviewTarget.WorkspacePath(
            sourceIdentity = target.sourceIdentity,
            previewPath = resolution.relativePath,
        )
        is PreviewResolution.Unresolved -> MarkdownResourcePreviewTarget.Refused(
            sourceIdentity = target.sourceIdentity,
            reason = when (resolution.reason) {
                PreviewUnresolved.REJECTED -> MarkdownResourceRefusal.UNSAFE_PATH
                PreviewUnresolved.MISSING, PreviewUnresolved.NOT_A_FILE -> MarkdownResourceRefusal.MISSING_PATH
                PreviewUnresolved.NO_WORKSPACE -> MarkdownResourceRefusal.NO_VERIFIED_WORKSPACE
            },
        )
    }
}

/**
 * Resolves only identities that can be mapped to the current verified workspace.
 * It performs no filesystem access; ChatRoute passes the returned path through the
 * real [PreviewFileSource.resolve] boundary before navigating.
 */
internal fun markdownResourcePreviewTarget(
    source: String,
    currentWorkerSessionId: String?,
    hasVerifiedWorkspaceRoot: Boolean,
): MarkdownResourcePreviewTarget {
    val target = markdownLinkTarget(source) as? MarkdownLinkTarget.ResourceUri
        ?: return MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
    val uri = runCatching { URI(target.value) }.getOrNull()
        ?: return MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
    return when (uri.scheme?.lowercase()) {
        "sandbox" -> MarkdownResourcePreviewTarget.WorkspacePath(source, source)
        "file" -> {
            if (uri.path.orEmpty().startsWith("/dsh/workspace/")) {
                MarkdownResourcePreviewTarget.WorkspacePath(source, source)
            } else {
                MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.ABSOLUTE_RESOURCE)
            }
        }
        "dsh-resource" -> {
            if (uri.host?.lowercase() != "file") {
                return MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
            }
            val segments = uri.path.orEmpty().split('/').filter(String::isNotEmpty)
            when (segments.firstOrNull()) {
                "absolute" -> MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.ABSOLUTE_RESOURCE)
                "session" -> {
                    if (segments.size < 3) {
                        return MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
                    }
                    val resourceSessionId = segments[1]
                    when {
                        currentWorkerSessionId.isNullOrBlank() -> MarkdownResourcePreviewTarget.Refused(
                            source,
                            MarkdownResourceRefusal.NO_CURRENT_SESSION,
                        )
                        resourceSessionId != currentWorkerSessionId -> MarkdownResourcePreviewTarget.Refused(
                            source,
                            MarkdownResourceRefusal.DIFFERENT_SESSION,
                        )
                        !hasVerifiedWorkspaceRoot -> MarkdownResourcePreviewTarget.Refused(
                            source,
                            MarkdownResourceRefusal.NO_VERIFIED_WORKSPACE,
                        )
                        else -> {
                            val tail = segments.drop(2)
                            val relative = if (tail.firstOrNull() == "dsh" && tail.getOrNull(1) == "workspace") {
                                tail.drop(2).joinToString("/")
                            } else {
                                tail.joinToString("/")
                            }
                            if (relative.isBlank()) {
                                MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
                            } else {
                                MarkdownResourcePreviewTarget.WorkspacePath(source, relative)
                            }
                        }
                    }
                }
                else -> MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
            }
        }
        else -> MarkdownResourcePreviewTarget.Refused(source, MarkdownResourceRefusal.INVALID)
    }
}
