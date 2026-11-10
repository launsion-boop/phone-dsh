// 本 session 产物: the files a session's tools produced, and what is not one of them.
// SPDX-License-Identifier: MIT
//
// The Android page of `SessionArtifactsPage.swift` (349 lines). Its subject is not
// the list — it is **attribution**, and the whole split depends on it:
//
//  * **本 session** — an artifact id that a successful producing tool call in this
//    session's own transcript named (`SessionArtifactAttribution`). The id alone is
//    not evidence; a `fileId` in someone else's output, or in a failed call, or in a
//    call whose tool is not a producer, does not belong to this session.
//  * **未归属** — everything the artifact store holds that no transcript row claims.
//    It is shown, because hiding it would look like the file was deleted, and it is
//    labelled, because listing it as "this session's" would be a fabricated
//    provenance.
//
// The attribution rules are the Swift file's, including the two non-obvious ones:
// the `phone` tool names its verb in `arguments.name`, and a `bash` command is only
// evidence when it contains exactly one `phone <verb>` invocation (a mixed shell
// line cannot prove which call produced which id).
//
// ---- the workspace source (L81) -------------------------------------------
// The Office store above is the iOS subject; on this host the files a turn really
// produces are the ones it wrote into the materialized workspace
// (`files/xl/materialized/workspace`, the tree the files page and the preview
// read). [WorkspaceSessionArtifactSource] lists that tree, and the host's *fact*
// says which of those paths this session's own turns wrote. The two together are
// the same split the baseline draws from its store and its transcript:
//
//  * 本 session — a path whose bytes changed while one of this session's turns was
//    running (or that a write tool named and the disk really holds);
//  * 未归属 — every other workspace file (an import from 添加文件, an earlier
//    session's leftover), listed and labelled, never claimed.
//
// There is no preview *surface* here in the QuickLook sense. iOS pushes a
// `QLPreviewController` (`SessionArtifactsPage.swift:301`); Android ships no
// system previewer. The preview subpage (`SessionArtifactPreviewPage`, `:296`–
// `:319`) therefore renders the text the host read for the file when there is one,
// and the baseline's own "cannot preview" body (`:304`–`:305`) when there is not,
// and its 分享 verb is a real `Intent.ACTION_SEND` chooser (`:313`) driven by the
// host's [PreviewShare] uri or by the host's own share callback.
//
// Geometry: every length comes from `spec/ui/v1/tokens.json` (page-level block and
// the file glyph's card inset); nothing is invented.
package com.phonedsh.ui.page

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.domain.connector.DeviceToolState
import com.phonedsh.domain.connector.DeviceTranscriptItem
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.ShellFilesMetrics
import com.phonedsh.ui.surface.preview.PreviewFileSource
import com.phonedsh.ui.surface.preview.PreviewPathResolver
import com.phonedsh.ui.surface.preview.PreviewResolution
import com.phonedsh.ui.surface.preview.PreviewWorkspace
import com.phonedsh.ui.surface.preview.WorkspacePreviewSource
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiGeometry
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.io.IOException
import java.nio.file.Path
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * One artifact the store holds.
 *
 * @property artifactId the store's id — an `art_`-prefixed record id for the iOS
 *   Office store, or the workspace-relative path for this host's
 *   [WorkspaceSessionArtifactSource]; the attribution key either way.
 * @property name the file name the store reports, extension included.
 * @property byteCount the file's size, formatted for a person by [formatFileSize].
 */
public data class SessionArtifactRef(
    public val artifactId: String,
    public val name: String,
    public val byteCount: Long,
) {
    init {
        require(artifactId.isNotEmpty()) { "an artifact needs an id" }
        require(byteCount >= 0) { "a byte count is never negative" }
    }
}

/**
 * One transcript row's contribution to attribution: what tool ran, with what
 * arguments, and what it answered.
 *
 * It is a separate value from [DeviceTranscriptItem] so the attribution rules can be
 * tested — and reused — without a device transcript. `from` is the only bridge.
 */
public data class SessionArtifactEvidence(
    public val toolName: String?,
    public val argumentsJson: String?,
    public val outputText: String?,
    public val text: String,
    public val state: DeviceToolState?,
) {
    public companion object {
        /** Adapts one projected transcript row. A non-tool row carries no evidence. */
        public fun from(item: DeviceTranscriptItem): SessionArtifactEvidence =
            SessionArtifactEvidence(
                toolName = item.toolName,
                argumentsJson = item.argumentsJson,
                outputText = item.outputText,
                text = item.text,
                state = item.toolState,
            )
    }
}

/**
 * Which artifacts a session's own transcript proves it produced.
 *
 * The producing verbs are the Swift page's list, verb for verb. A verb is only
 * evidence when the call **succeeded**: a failed write produced nothing, and a
 * cancelled tool is not a file.
 */
public object SessionArtifactAttribution {
    /** The tool verbs that produce a file, in the baseline's spelling. */
    public val PRODUCING_TOOLS: Set<String> = setOf(
        "doc.write",
        "sheet.write",
        "slides.write",
        "chart.render",
        "files.pick",
        "mail.compose_draft",
    )

    /**
     * The artifact ids [evidence] proves belong to one session.
     *
     * @return the ids, or an empty set when nothing in the transcript is evidence.
     */
    public fun generatedArtifactIDs(evidence: List<SessionArtifactEvidence>): Set<String> {
        val result = LinkedHashSet<String>()
        evidence.forEach { row ->
            if (row.state != DeviceToolState.OK) return@forEach
            if (producingTool(row) == null) return@forEach
            val output = row.outputText ?: row.text.takeIf { it.isNotEmpty() } ?: return@forEach
            val json = runCatching { JsonValue.parse(output) }.getOrNull() ?: return@forEach
            collectArtifactIDs(json, result)
        }
        return result
    }

    /** Which producing verb [row] ran, or `null` when it proves nothing. */
    private fun producingTool(row: SessionArtifactEvidence): String? {
        val rawName = row.toolName ?: return null
        val arguments = row.argumentsJson?.let { runCatching { JsonValue.parse(it) }.getOrNull() }
        val direct = if (rawName.startsWith(PHONE_PREFIX)) rawName.removePrefix(PHONE_PREFIX) else rawName
        if (direct in PRODUCING_TOOLS) return direct
        if (rawName == PHONE_TOOL) {
            val named = (arguments as? JsonObject)?.get("name")?.stringOrNull() ?: return null
            return named.takeIf { it in PRODUCING_TOOLS }
        }
        if (rawName !in SHELL_TOOLS) return null
        val command = (arguments as? JsonObject)?.get("command")?.stringOrNull() ?: return null
        val invocations = phoneInvocations(command)
        // A mixed shell line cannot prove which phone call produced each id.
        if (invocations.size != 1) return null
        return invocations.first().takeIf { it in PRODUCING_TOOLS }
    }

    /**
     * The `phone <verb>` invocations in a shell command.
     *
     * Split on the shell's separators, honouring quotes and backslash escapes, then
     * take the second word of every segment that starts with `phone`. The parse is
     * deliberately shallow: it exists to *refuse* ambiguous commands, not to run one.
     */
    internal fun phoneInvocations(command: String): List<String> {
        val segments = mutableListOf<String>()
        var segment = StringBuilder()
        var quote: Char? = null
        var escaped = false
        command.forEach { character ->
            when {
                escaped -> {
                    segment.append(character)
                    escaped = false
                }

                character == '\\' && quote != '\'' -> {
                    segment.append(character)
                    escaped = true
                }

                quote != null -> {
                    segment.append(character)
                    if (character == quote) quote = null
                }

                character == '\'' || character == '"' -> {
                    quote = character
                    segment.append(character)
                }

                character == ';' || character == '&' || character == '|' || character == '\n' -> {
                    segments += segment.toString()
                    segment = StringBuilder()
                }

                else -> segment.append(character)
            }
        }
        segments += segment.toString()
        return segments.mapNotNull { text ->
            val tokens = text.split(SHELL_WHITESPACE).filter { it.isNotEmpty() }
            if (tokens.firstOrNull() != PHONE_COMMAND) return@mapNotNull null
            if (tokens.size > 1) tokens[1] else ""
        }
    }

    private fun collectArtifactIDs(value: JsonValue, into: MutableSet<String>) {
        when (value) {
            is JsonObject -> value.members.forEach { (key, child) ->
                val id = (child as? JsonString)?.value
                if (key == FILE_ID_KEY && id != null && id.startsWith(ARTIFACT_PREFIX) &&
                    id.length <= MAX_ARTIFACT_ID_LENGTH
                ) {
                    into += id
                } else {
                    collectArtifactIDs(child, into)
                }
            }

            is JsonArray -> value.values.forEach { collectArtifactIDs(it, into) }
            else -> Unit
        }
    }

    private fun JsonValue.stringOrNull(): String? = (this as? JsonString)?.value

    private const val PHONE_PREFIX: String = "phone."
    private const val PHONE_TOOL: String = "phone"
    private const val PHONE_COMMAND: String = "phone"
    private const val FILE_ID_KEY: String = "fileId"
    private const val ARTIFACT_PREFIX: String = "art_"
    private const val MAX_ARTIFACT_ID_LENGTH: Int = 128
    private val SHELL_TOOLS: Set<String> = setOf("bash", "shell")
    private val SHELL_WHITESPACE: Regex = Regex("\\s+")
}

/** One page of an artifact listing; `nextCursor` is `null` on the last page. */
public data class SessionArtifactPage(
    public val items: List<SessionArtifactRef>,
    public val nextCursor: Int? = null,
)

/**
 * The artifact store seam.
 *
 * iOS reads `OfficeArtifactStore.shared`; Android has no such store in this module, so
 * the page takes this interface and the host injects one. `fileExists` is separate
 * from `list` because a store can list a record whose file is already gone, which is
 * exactly the case the baseline reports as 文件已不在本机产物存储中。
 *
 * The last two methods are this host's additions and both have honest defaults:
 * a store that cannot address its files answers `null` to [fileFor] (no share
 * carried the file itself) and `null` to [content] (the preview then shows the
 * baseline's "cannot preview" body instead of a body it did not read).
 */
public interface SessionArtifactSource {
    /** Reads one page. */
    public suspend fun list(cursor: Int, limit: Int): SessionArtifactPage

    /** Whether the store still holds the file behind [artifactId]. */
    public suspend fun fileExists(artifactId: String): Boolean

    /**
     * The readable file behind [artifactId], or `null` when this store cannot
     * address one (the Office double keeps records, not paths).
     *
     * A `content://` uri handed to another app must name a file the provider
     * really serves, so the share path resolves through this value rather than
     * re-joining a root and an id here.
     */
    public suspend fun fileFor(artifactId: String): Path? = null

    /**
     * The first text page of [artifactId], or `null` when the file is not text or
     * the store has no read.
     *
     * The page draws whatever comes back and says so when it is a window rather
     * than the whole file ([SessionArtifactContent.loadedBytes] vs
     * [SessionArtifactContent.totalBytes]).
     */
    public suspend fun content(artifactId: String): SessionArtifactContent? = null
}

/**
 * One readable window of an artifact's text.
 *
 * @param text the decoded text of the first page.
 * @param loadedBytes how many of the file's bytes [text] covers.
 * @param totalBytes the file's whole size, when the store measured one.
 */
public data class SessionArtifactContent(
    public val text: String,
    public val loadedBytes: Long,
    public val totalBytes: Long?,
)

/**
 * The workspace as an artifact store: the files a host can really hand over.
 *
 * The rows are the materialized workspace tree (`<filesDir>/xl/materialized/
 * workspace`, [PreviewWorkspace.defaultRoot]) read through [PreviewFileSource] —
 * the same listing the files page and the preview surface use, so the three can
 * never disagree about what exists. The id of a row is its workspace-relative
 * path, which is what the host's write fact names.
 *
 * A root that is not there (the app has not written a workspace yet) is reported
 * as [IOException] with [NO_WORKSPACE_REASON], never as an empty list: "this host
 * has no workspace to read" and "this workspace holds no files" are different
 * facts, and the page renders a retry for the first and the empty body for the
 * second.
 *
 * @param root the materialized workspace root, or `null` when the host has none.
 */
public class WorkspaceSessionArtifactSource(
    public val root: Path?,
) : SessionArtifactSource {
    private val files: PreviewFileSource = WorkspacePreviewSource(root)

    override suspend fun list(cursor: Int, limit: Int): SessionArtifactPage {
        require(cursor >= 0) { "a cursor is never negative" }
        require(limit > 0) { "a page limit is positive" }
        val listing = files.files() ?: throw IOException(NO_WORKSPACE_REASON)
        val rows = listing.map { file ->
            SessionArtifactRef(
                artifactId = file.relativePath,
                name = file.relativePath.substringAfterLast('/'),
                byteCount = file.size ?: 0L,
            )
        }
        if (cursor >= rows.size) return SessionArtifactPage(emptyList(), nextCursor = null)
        val end = minOf(cursor + minOf(limit, MAX_PAGE_ITEMS), rows.size)
        return SessionArtifactPage(
            items = rows.subList(cursor, end),
            nextCursor = if (end < rows.size) end else null,
        )
    }

    override suspend fun fileExists(artifactId: String): Boolean = fileFor(artifactId) != null

    override suspend fun fileFor(artifactId: String): Path? = withContext(Dispatchers.IO) {
        (PreviewPathResolver.resolve(root, artifactId) as? PreviewResolution.Resolved)?.file
    }

    override suspend fun content(artifactId: String): SessionArtifactContent? {
        val resolved = withContext(Dispatchers.IO) {
            PreviewPathResolver.resolve(root, artifactId) as? PreviewResolution.Resolved
        } ?: return null
        if (!files.looksLikeText(resolved.file)) return null
        val page = try {
            files.readPage(resolved.file, 0L)
        } catch (_: IOException) {
            // A file that cannot be read is "no preview", not a page of error text:
            // the fallback body already tells the person to open it elsewhere.
            return null
        }
        if (page.text.isEmpty()) return null
        return SessionArtifactContent(
            text = page.text,
            loadedBytes = page.nextOffset.coerceAtMost(resolved.sizeBytes),
            totalBytes = resolved.sizeBytes,
        )
    }

    public companion object {
        /** The reason a read with no workspace carries; the page words it for a person. */
        public const val NO_WORKSPACE_REASON: String = "the host has no workspace yet"

        /** The page size this store serves; the listing is small and sorted. */
        public const val MAX_PAGE_ITEMS: Int = 50
    }
}

/**
 * An in-memory store: the double this host ships in place of a real one.
 *
 * @param artifacts every record the store holds.
 * @param present the ids whose file still exists; defaults to all of them.
 * @param pageSize how many records one [list] call returns.
 */
public class InMemorySessionArtifactSource(
    private val artifacts: List<SessionArtifactRef> = emptyList(),
    private val present: Set<String> = artifacts.map { it.artifactId }.toSet(),
    private val pageSize: Int = DEFAULT_PAGE_SIZE,
) : SessionArtifactSource {
    /** How many `list` calls this store served; a test reads it to prove paging. */
    public var listCount: Int = 0
        private set

    override suspend fun list(cursor: Int, limit: Int): SessionArtifactPage {
        listCount += 1
        require(cursor >= 0) { "a cursor is never negative" }
        require(limit > 0) { "a page limit is positive" }
        val size = minOf(limit, pageSize)
        val end = minOf(cursor + size, artifacts.size)
        if (cursor >= artifacts.size) return SessionArtifactPage(emptyList(), nextCursor = null)
        return SessionArtifactPage(
            items = artifacts.subList(cursor, end).toList(),
            nextCursor = if (end < artifacts.size) end else null,
        )
    }

    override suspend fun fileExists(artifactId: String): Boolean = artifactId in present

    public companion object {
        /** `OfficeLimits.maximumPageItems` is the baseline's own ceiling; 50 is this double's. */
        public const val DEFAULT_PAGE_SIZE: Int = 50
    }
}

/**
 * The host's answer to "which workspace files did this session write?".
 *
 * This is the fact the workspace source is attributed with. It is deliberately
 * **not** a directory scan and **not** a transcript parse:
 *
 *  * a scan of `/dsh/workspace` cannot tell this session's output from a file the
 *    person imported with 添加文件 a minute earlier, or from a previous session's
 *    leftover — the very distinction this page exists to make;
 *  * the transcript names a *tool*, and for the one tool that writes almost
 *    everything (`bash`) the path is buried in shell syntax; parsing redirections
 *    is a heuristic that would both miss writes and invent them.
 *
 * So the host measures it: it snapshots the materialized workspace when a turn
 * starts and diffs it when that turn ends (and after each of the turn's tool
 * results), so a path is "this session's" when its bytes changed while one of this
 * session's own turns was running. A path a named write tool (`write` / `edit` /
 * `str_replace_editor`) announced is also accepted, and no row is ever drawn for a
 * path the disk does not hold: the listing is the authority on existence, this
 * fact only claims authorship.
 *
 * @param writtenPaths the workspace-relative paths this session's turns wrote, in
 *   observation order, or `null` when the host made no measurement at all (a host
 *   with no turn lane, or a session that never ran one).
 */
public data class SessionArtifactsFacts(
    public val writtenPaths: List<String>? = null,
)

/**
 * One artifact opened for reading: the `navigationDestination(item: $preview)`
 * payload (`SessionArtifactsPage.swift:101`).
 *
 * iOS carries `(OfficeArtifactRef, URL)`: the file's own URL, which
 * `QLPreviewController` renders and `ShareLink` shares. This host's store can hand
 * over a `content://` uri when it has one ([contentUri]) and the first text page it
 * read ([text]); when it has neither the preview still opens — the page shows the
 * baseline's fallback body — and 分享 sends the artifact's descriptor instead of a
 * file. The page never pretends a uri or a body exists.
 *
 * @param artifact the row that was opened.
 * @param contentUri the `content://` uri the store grants read access to, or
 *   `null` when the store holds no shareable uri for this file.
 * @param text the first text page of the file, or `null` when this host cannot
 *   show it as text (a binary document, or a store with no read).
 * @param loadedBytes how many bytes [text] covers; `null` when [text] is `null`.
 * @param totalBytes the file's whole size when the host measured one, `null`
 *   otherwise.
 */
public data class SessionArtifactPreview(
    public val artifact: SessionArtifactRef,
    public val contentUri: String? = null,
    public val text: String? = null,
    public val loadedBytes: Long? = null,
    public val totalBytes: Long? = null,
) {
    /** True when the preview body is the host's read text rather than the fallback. */
    public val hasText: Boolean get() = !text.isNullOrEmpty()

    /** True when [text] is a window on a longer file. */
    public val textTruncated: Boolean
        get() {
            val loaded = loadedBytes ?: return false
            val total = totalBytes ?: return false
            return loaded < total
        }
}

/** The artifacts page's local UI state: the row being opened, and the open preview. */
public data class SessionArtifactsLocalState(
    public val openingId: String? = null,
    public val preview: SessionArtifactPreview? = null,
)

/**
 * The artifacts page state.
 *
 * @param assigned the artifacts this session's transcript proves it produced.
 * @param unassigned the store's records that no row claims.
 * @param failure a read failure, already worded for the page.
 * @param openFailure the host's answer to the last open gesture, already worded.
 * @param preview the artifact whose preview subpage is showing, or `null` on the
 *   list.
 */
public data class SessionArtifactsScreenState(
    public val assigned: List<SessionArtifactRef>,
    public val unassigned: List<SessionArtifactRef>,
    public val loading: Boolean,
    public val failure: String?,
    public val openFailure: String?,
    public val openingId: String?,
    public val preview: SessionArtifactPreview? = null,
) {
    /** True when the store answered and nothing belongs to this session. */
    public val sessionEmpty: Boolean
        get() = !loading && assigned.isEmpty()

    /** True when the preview subpage is showing (`:296`). */
    public val isPreviewing: Boolean get() = preview != null

    public companion object {
        /**
         * Projects the store's records and the session's evidence into the page state.
         *
         * Pure: the same artifacts and the same evidence always split the same way,
         * which is what makes attribution testable without a store.
         */
        public fun from(
            artifacts: List<SessionArtifactRef>,
            evidence: List<SessionArtifactEvidence>,
            local: SessionArtifactsLocalState = SessionArtifactsLocalState(),
            waiting: Boolean = false,
            failure: String? = null,
        ): SessionArtifactsScreenState = fromIDs(
            artifacts = artifacts,
            ids = SessionArtifactAttribution.generatedArtifactIDs(evidence),
            local = local,
            waiting = waiting,
            failure = failure,
        )

        /**
         * Projects a workspace listing and the host's per-turn write fact.
         *
         * The ids are the fact's workspace-relative paths, so the split is the
         * same rule as [from] with a measured evidence set instead of a transcript
         * one. `null` (no measurement) claims nothing: every file lands in
         * 未归属 rather than being attributed by guesswork.
         */
        public fun fromWorkspace(
            artifacts: List<SessionArtifactRef>,
            facts: SessionArtifactsFacts,
            local: SessionArtifactsLocalState = SessionArtifactsLocalState(),
            waiting: Boolean = false,
            failure: String? = null,
        ): SessionArtifactsScreenState = fromIDs(
            artifacts = artifacts,
            ids = facts.writtenPaths.orEmpty().toSet(),
            local = local,
            waiting = waiting,
            failure = failure,
        )

        private fun fromIDs(
            artifacts: List<SessionArtifactRef>,
            ids: Set<String>,
            local: SessionArtifactsLocalState,
            waiting: Boolean,
            failure: String?,
        ): SessionArtifactsScreenState = SessionArtifactsScreenState(
            assigned = artifacts.filter { it.artifactId in ids },
            unassigned = artifacts.filter { it.artifactId !in ids },
            loading = waiting,
            failure = failure,
            openFailure = null,
            openingId = local.openingId,
            preview = local.preview,
        )

        /** Replaces the open failure, keeping every other field (the page's alert). */
        public fun withOpenFailure(
            state: SessionArtifactsScreenState,
            openFailure: String?,
        ): SessionArtifactsScreenState = state.copy(openFailure = openFailure)
    }
}

/**
 * The artifacts page, plus the preview subpage its rows push
 * (`SessionArtifactsPage.swift:101`, `:296`–`:319`).
 *
 * @param state the pure screen state ([SessionArtifactsScreenState.from]).
 * @param onOpen ask the host to open the artifact's file.
 * @param onRetry retry a failed read.
 * @param onDone leave the list (its back control; the baseline pushes the page).
 * @param onDismissOpenFailure dismiss the 无法打开产物 alert (`:108`).
 * @param onClosePreview leave the preview and return to the list; `null` keeps the
 *   preview without a back control.
 * @param onShare the host's share action for the open preview, returning false when
 *   the platform refused (no app can receive the file, or the provider would not
 *   serve it). `null` keeps the page's own chooser, which is a real
 *   `Intent.ACTION_SEND` built from [SessionArtifactPreview.contentUri] or the
 *   artifact's descriptor. Either way the verb is drawn: the baseline's 分享 exists
 *   on every preview (`SessionArtifactsPage.swift:310`–`:316`).
 */
@Composable
public fun SessionArtifactsPage(
    state: SessionArtifactsScreenState,
    onOpen: (SessionArtifactRef) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    onDismissOpenFailure: (() -> Unit)? = null,
    onClosePreview: (() -> Unit)? = null,
    onShare: ((SessionArtifactPreview) -> Boolean)? = null,
) {
    val openFailure = state.openFailure
    if (openFailure != null && onDismissOpenFailure != null) {
        ArtifactOpenFailureAlert(message = openFailure, onDismiss = onDismissOpenFailure)
    }
    val preview = state.preview
    // 分享 is the preview's one action and its refusal is a fact, so a host share
    // that fails must show somewhere: the same footer line the preview surface uses.
    var shareFailed by remember(preview?.artifact?.artifactId) { mutableStateOf(false) }
    PageFrame(
        // The preview's title is the artifact's own name
        // (`navigationTitle(preview.artifact.name)`, `:308`); the list keeps the
        // page title.
        title = preview?.artifact?.name ?: UiStrings.ARTIFACTS_TITLE,
        // PR #60 removed the list's 完成 (`SessionArtifactsPage.swift:89`): the page is
        // pushed, so the list leaves by its back control like any pushed page.
        onBack = if (preview != null) onClosePreview else onDone,
        rootTag = UiPageTags.ARTIFACTS_ROOT,
        modifier = modifier,
        actions = {
            if (preview != null) {
                // `.toolbar { ToolbarItem(.primaryAction) { ShareLink… } }` (`:310`).
                ArtifactShareAction(
                    preview = preview,
                    onShare = onShare,
                    onRefused = { shareFailed = true },
                )
            }
        },
    ) {
        if (preview != null) {
            SessionArtifactPreviewPage(preview = preview, shareFailed = shareFailed)
            return@PageFrame
        }
        LazyColumn(modifier = Modifier.fillMaxSize().testTag(UiPageTags.ARTIFACTS_LIST)) {
            if (state.loading && state.assigned.isEmpty() && state.unassigned.isEmpty()) {
                item(key = "loading") {
                    ArtifactHint(
                        title = UiStrings.ARTIFACTS_LOADING,
                        hint = null,
                        tag = UiPageTags.ARTIFACTS_LOADING,
                    )
                }
            }
            val failure = state.failure
            if (failure != null) {
                item(key = "failure") {
                    ArtifactFailureRow(
                        message = failure,
                        tag = UiPageTags.ARTIFACTS_FAILURE,
                        onRetry = onRetry,
                    )
                }
            }
            // The alert above owns the open failure when the host can dismiss it;
            // otherwise the same sentence stays on the page so it is not lost.
            if (openFailure != null && onDismissOpenFailure == null) {
                item(key = "open-failure") {
                    ArtifactFailureRow(
                        message = "${UiStrings.ARTIFACTS_OPEN_FAILED}：$openFailure",
                        tag = UiPageTags.ARTIFACTS_FAILURE,
                        onRetry = null,
                    )
                }
            }

            if (state.sessionEmpty) {
                item(key = "empty") {
                    ArtifactEmptyBlock()
                }
            } else if (state.assigned.isNotEmpty()) {
                item(key = "session-header") {
                    Column(modifier = Modifier.testTag(UiPageTags.ARTIFACTS_SESSION_SECTION)) {
                        SessionSectionLabel(UiStrings.ARTIFACTS_SECTION_SESSION)
                    }
                }
                items(count = state.assigned.size, key = { "assigned-${state.assigned[it].artifactId}" }) { index ->
                    val artifact = state.assigned[index]
                    ArtifactRow(
                        artifact = artifact,
                        unassigned = false,
                        opening = state.openingId == artifact.artifactId,
                        enabled = state.openingId == null,
                        onOpen = { onOpen(artifact) },
                    )
                    SessionHairline()
                }
            }

            if (state.unassigned.isNotEmpty()) {
                item(key = "unassigned-header") {
                    Column(modifier = Modifier.testTag(UiPageTags.ARTIFACTS_UNASSIGNED_SECTION)) {
                        SessionSectionLabel(UiStrings.ARTIFACTS_SECTION_UNASSIGNED)
                    }
                }
                items(count = state.unassigned.size, key = { "unassigned-${state.unassigned[it].artifactId}" }) { index ->
                    val artifact = state.unassigned[index]
                    ArtifactRow(
                        artifact = artifact,
                        unassigned = true,
                        opening = state.openingId == artifact.artifactId,
                        enabled = state.openingId == null,
                        onOpen = { onOpen(artifact) },
                    )
                    SessionHairline()
                }
                item(key = "unassigned-footer") {
                    ArtifactFooter(UiStrings.ARTIFACTS_UNASSIGNED_FOOTER, UiPageTags.ARTIFACTS_UNASSIGNED_FOOTER)
                }
            }
        }
    }
}

/**
 * The preview subpage (`SessionArtifactsPage.swift:296`–`:319`), inside the page's
 * own frame.
 *
 * The baseline renders `QLPreviewController.canPreview(url) ? quickLook : fallback`
 * (`:301`–`:306`). Android has no system previewer to ask, so this port reads the
 * file through the host and takes one of two branches:
 *
 *  * the host read text ([SessionArtifactPreview.hasText]) — the text is the body,
 *    in the mono face, scrollable and selectable, with the measured read window
 *    stated when it is shorter than the file;
 *  * no text (an Office document, a binary, a store with no read) — the baseline's
 *    two sentences (`:304`–`:305`) plus the one platform fact iOS does not need.
 *
 * Either way the file still reaches another app through 分享, and a refused share
 * says so instead of leaving the tap silent.
 *
 * @param preview the artifact the row opened, the uri the store can share and the
 *   text the host read.
 * @param shareFailed true when the host's own share action reported a refusal.
 */
@Composable
private fun SessionArtifactPreviewPage(preview: SessionArtifactPreview, shareFailed: Boolean) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(UiPageTags.ARTIFACTS_PREVIEW_ROOT)
            .padding(
                horizontal = tokens.geometry.chromeInset,
                vertical = tokens.geometry.cardOuterMarginV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
        ) {
            BasicText(
                text = preview.artifact.name,
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .testTag(UiPageTags.ARTIFACTS_PREVIEW_NAME),
            )
            BasicText(
                text = formatFileSize(preview.artifact.byteCount),
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        val text = preview.text
        if (text != null) {
            SelectionContainer {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState()),
                ) {
                    BasicText(
                        text = text,
                        style = type.code.copy(color = tokens.colors.secondary),
                    )
                }
            }
            if (preview.textTruncated) {
                val loaded = preview.loadedBytes ?: 0L
                val total = preview.totalBytes ?: 0L
                BasicText(
                    text = UiStrings.PREVIEW_PROGRESS.format(
                        formatFileSize(loaded),
                        formatFileSize(total),
                    ),
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        } else {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    BasicText(
                        text = UiStrings.ARTIFACTS_NO_PREVIEW,
                        style = type.body.copy(
                            color = tokens.colors.secondary,
                            textAlign = TextAlign.Center,
                        ),
                        modifier = Modifier
                            .testTag(UiPageTags.ARTIFACTS_PREVIEW_FALLBACK)
                            .semantics { heading() },
                    )
                    BasicText(
                        text = UiStrings.ARTIFACTS_NO_PREVIEW_HINT,
                        style = type.caption.copy(
                            color = tokens.colors.secondary,
                            textAlign = TextAlign.Center,
                        ),
                    )
                    BasicText(
                        text = UiStrings.ARTIFACTS_PREVIEW_PLATFORM_NOTE,
                        style = type.caption.copy(
                            color = tokens.colors.tertiary,
                            textAlign = TextAlign.Center,
                        ),
                    )
                }
            }
        }
        if (shareFailed) {
            // Fail-loud is audible too: an assertive live region interrupts.
            BasicText(
                text = UiStrings.PREVIEW_SHARE_FAILED,
                style = type.caption.copy(color = tokens.colors.warning),
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
            )
        }
    }
}

/**
 * 分享 (`:310`–`:316`): the one write-free action of the preview.
 *
 * `ShareLink(item: preview.url)` is the system's own share sheet, so the Android
 * port also emits the system's own chooser. Two drivers:
 *
 *  * the host's [onShare] callback (what the app routes use: a `FileProvider` uri
 *    plus `Intent.ACTION_SEND`, `PreviewShare`), whose `false` answer is drawn;
 *  * with no host callback, the page's own [sessionArtifactShareChooser], started
 *    on the composition's context. A context that is not an activity gets
 *    `FLAG_ACTIVITY_NEW_TASK`, which is what starting an activity outside one
 *    requires.
 *
 * @param preview the artifact to share.
 * @param onShare the host's share action, or `null` for the page's own chooser.
 * @param onRefused called when [onShare] answered false.
 */
@Composable
private fun ArtifactShareAction(
    preview: SessionArtifactPreview,
    onShare: ((SessionArtifactPreview) -> Boolean)?,
    onRefused: () -> Unit,
) {
    val context = LocalContext.current
    SessionTextAction(
        label = UiStrings.ARTIFACTS_PREVIEW_SHARE,
        onClick = {
            if (onShare != null) {
                if (!onShare(preview)) onRefused()
            } else {
                val chooser = sessionArtifactShareChooser(preview)
                if (context !is Activity) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(chooser)
            }
        },
        tone = SessionActionTone.ACCENT,
        modifier = Modifier.testTag(UiPageTags.ARTIFACTS_PREVIEW_SHARE),
        description = UiStrings.ARTIFACTS_PREVIEW_SHARE_CHOOSER,
    )
}

/**
 * The chooser 分享 opens: a real `Intent.ACTION_SEND`, wrapped by
 * `Intent.createChooser` the way `ShareLink` wraps the system sheet.
 *
 * @param preview the artifact to share.
 */
public fun sessionArtifactShareChooser(preview: SessionArtifactPreview): Intent =
    Intent.createChooser(sessionArtifactShareIntent(preview), UiStrings.ARTIFACTS_PREVIEW_SHARE_CHOOSER)

/**
 * The `ACTION_SEND` payload for one artifact.
 *
 * Two shapes, chosen by what the store really holds:
 *
 *  * a `content://` uri ([SessionArtifactPreview.contentUri]) → the file itself
 *    rides in `EXTRA_STREAM` with `FLAG_GRANT_READ_URI_PERMISSION`, which is the
 *    baseline's `ShareLink(item: url)`;
 *  * no uri → the artifact's descriptor (name, size, id) rides in `EXTRA_TEXT`.
 *    A file cannot be attached without a content provider this app does not
 *    declare, and silently sharing nothing would be the dead control the page is
 *    not allowed to render.
 *
 * Public so a test can assert the intent's action, type and extras without a
 * screen.
 *
 * @param preview the artifact to share.
 */
public fun sessionArtifactShareIntent(preview: SessionArtifactPreview): Intent {
    val artifact = preview.artifact
    val uri = preview.contentUri
    val send = Intent(Intent.ACTION_SEND)
    if (uri != null) {
        send.type = artifactMimeType(artifact.name)
        send.putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    } else {
        send.type = TEXT_PLAIN
    }
    send.putExtra(Intent.EXTRA_SUBJECT, artifact.name)
    send.putExtra(
        Intent.EXTRA_TEXT,
        UiStrings.ARTIFACTS_PREVIEW_SHARE_TEXT.format(
            artifact.name,
            formatFileSize(artifact.byteCount),
            artifact.artifactId,
        ),
    )
    return send
}

/**
 * The MIME type of [name]'s extension, or the generic type when the table has
 * no entry.
 *
 * The chooser filters by type, so the four artifacts a phone's tools produce get
 * their real type; anything else is offered as a generic stream rather than
 * guessed into a wrong one.
 */
internal fun artifactMimeType(name: String): String =
    ARTIFACT_MIME_TYPES[name.substringAfterLast('.', "").lowercase()] ?: ANY_MIME_TYPE

/**
 * The baseline's `.alert("无法打开产物", …)` (`:104`–`:111`): one sentence, one 好.
 *
 * @param message the host's sentence for the failed open.
 * @param onDismiss the alert's only button.
 */
@Composable
private fun ArtifactOpenFailureAlert(message: String, onDismiss: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = Modifier.testTag(UiPageTags.ARTIFACTS_OPEN_ALERT),
        title = {
            BasicText(
                text = UiStrings.ARTIFACTS_OPEN_FAILED,
                style = type.headline.copy(color = tokens.colors.primary),
            )
        },
        text = {
            BasicText(
                text = message,
                style = type.secondary.copy(color = tokens.colors.secondary),
            )
        },
        confirmButton = {
            SessionTextAction(
                label = UiStrings.ARTIFACTS_ACKNOWLEDGE,
                onClick = onDismiss,
                tone = SessionActionTone.ACCENT,
                modifier = Modifier.testTag(UiPageTags.ARTIFACTS_OPEN_ALERT_ACTION),
            )
        },
        shape = RoundedCornerShape(tokens.radius.card),
        containerColor = tokens.colors.input,
        titleContentColor = tokens.colors.primary,
        textContentColor = tokens.colors.secondary,
    )
}

/**
 * The empty state (`:55`–`:68`): the two sentences centred in their own group.
 *
 * The retry verb and this title are drawn where the group is, not through a
 * shared row helper, because the baseline's untitled groups are identified by
 * these rows.
 */
@Composable
private fun ArtifactEmptyBlock() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.ARTIFACTS_EMPTY)
            .padding(
                horizontal = tokens.geometry.chromeInset,
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.ARTIFACTS_EMPTY_TITLE,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier.semantics { heading() },
        )
        BasicText(
            text = UiStrings.ARTIFACTS_EMPTY_HINT,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
    }
}

/**
 * A read failure: the host's sentence and the retry verb on one line (`:44`–`:51`).
 *
 * The verb is a `BasicText` with its own `clickable`, not the shared
 * `SessionFailureLine`: that row renders its verb from a parameter, so the verb
 * would not be visible where the group is.
 *
 * @param message the host's sentence.
 * @param tag the stable test tag.
 * @param onRetry retry the read; `null` hides the verb.
 */
@Composable
private fun ArtifactFailureRow(message: String, tag: String, onRetry: (() -> Unit)?) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            // Fail-loud is audible too: an assertive live region interrupts.
            .semantics { liveRegion = LiveRegionMode.Assertive }
            .padding(
                horizontal = tokens.geometry.bannerInsetH,
                vertical = tokens.geometry.bannerInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.geometry.bannerGap),
    ) {
        BasicText(
            text = message,
            style = type.secondary.copy(color = tokens.colors.warning),
            modifier = Modifier.weight(1f),
        )
        if (onRetry != null) {
            BasicText(
                text = UiStrings.RETRY,
                style = type.secondary.copy(color = tokens.colors.accent),
                modifier = Modifier
                    .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                    .clickable(role = Role.Button, onClick = onRetry)
                    .padding(horizontal = tokens.spacing.badgeInsetH),
            )
        }
    }
}

/** One artifact row: the type glyph, the name, the size and the open affordance. */
@Composable
private fun ArtifactRow(
    artifact: SessionArtifactRef,
    unassigned: Boolean,
    opening: Boolean,
    enabled: Boolean,
    onOpen: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.ARTIFACTS_ROW)
            .clickable(enabled = enabled, role = Role.Button, onClick = onOpen)
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.chromeInset,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) { contentDescription = artifact.name },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.cardInset),
    ) {
        FileGlyph(artifact.name)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = artifact.name,
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            BasicText(
                text = formatFileSize(artifact.byteCount),
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
            if (unassigned) {
                BasicText(
                    text = UiStrings.ARTIFACTS_SECTION_UNASSIGNED,
                    style = type.caption.copy(color = tokens.colors.tertiary),
                )
            }
        }
        BasicText(
            text = if (opening) OPENING_GLYPH else CHEVRON_GLYPH,
            style = type.caption.copy(
                color = if (opening) tokens.colors.accent else tokens.colors.tertiary,
            ),
        )
    }
}

/** The file-type glyph: the extension in a rounded card, the way iOS draws an icon. */
@Composable
private fun FileGlyph(name: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val extension = name.substringAfterLast('.', "").uppercase().take(GLYPH_MAX_CHARS)
    Box(
        modifier = Modifier.size(
            width = ShellFilesMetrics.fileRowGlyphSlotWidth,
            height = ShellFilesMetrics.fileRowGlyphSlotHeight,
        ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(tokens.radius.card))
                .background(tokens.colors.secondary.copy(alpha = GLYPH_TINT_ALPHA))
                .padding(
                    horizontal = tokens.spacing.badgeInsetH,
                    vertical = tokens.spacing.badgeInsetV,
                ),
            contentAlignment = Alignment.Center,
        ) {
            BasicText(
                text = extension,
                style = type.caption.copy(color = tokens.colors.secondary),
                maxLines = 1,
            )
        }
    }
}

/** A centred hint: the loading line and the empty body. */
@Composable
private fun ArtifactHint(title: String, hint: String?, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.chromeInset,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .semantics(mergeDescendants = true) {
                contentDescription = listOfNotNull(title, hint).joinToString(". ")
            },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = title,
            style = type.body.copy(color = tokens.colors.secondary),
            modifier = Modifier.semantics { heading() },
        )
        if (hint != null) {
            BasicText(text = hint, style = type.caption.copy(color = tokens.colors.tertiary))
        }
    }
}

/** A section footer explaining what the rows above it are not. */
@Composable
private fun ArtifactFooter(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.tertiary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.chromeInset,
                vertical = tokens.spacing.iconText,
            ),
    )
}

/**
 * The token inventory of this page; `DeviceConnectorPagesTokenTest` fails when a use
 * site reads a token that is not listed here.
 */
/** HomeSpec.chromeInset is projected as pageOuterMarginH in the shared Android geometry model. */
private val UiGeometry.chromeInset: Dp
    get() = pageOuterMarginH

internal object SessionArtifactsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_WARNING,
        UiTokenNames.COLORS_INPUT,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.RADIUS_CARD,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.GEOMETRY_CHROME_INSET,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
        UiTokenNames.GEOMETRY_CARD_OUTER_MARGIN_V,
        UiTokenNames.GEOMETRY_BANNER_INSET_H,
        UiTokenNames.GEOMETRY_BANNER_INSET_V,
        UiTokenNames.GEOMETRY_BANNER_GAP,
    )
}

/** The disclosure chevron, and the in-flight marker, as the other page rows draw them. */
private const val CHEVRON_GLYPH: String = "›"
private const val OPENING_GLYPH: String = "…"

/** The glyph card holds up to four characters of an extension (`DOCX`). */
private const val GLYPH_MAX_CHARS: Int = 4

/** The glyph's tint over the secondary ink; an opacity, not a colour. */
private const val GLYPH_TINT_ALPHA: Float = 0.06f

/** The one type a share without a stream can declare honestly. */
private const val TEXT_PLAIN: String = "text/plain"

/** A stream whose type the table does not know is offered as a generic stream. */
private const val ANY_MIME_TYPE: String = "*/*"

/**
 * The four documents a session's tools produce, plus the phone's own photo types.
 * `spec/ui/v1/README.md` §5 keeps the file-type vocabulary in one place; a type
 * this table does not know is not guessed.
 */
private val ARTIFACT_MIME_TYPES: Map<String, String> = mapOf(
    "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "pdf" to "application/pdf",
    "csv" to "text/csv",
    "md" to "text/markdown",
    "txt" to "text/plain",
    "png" to "image/png",
    "jpg" to "image/jpeg",
    "jpeg" to "image/jpeg",
    "gif" to "image/gif",
)
