// Files: the workspace browser and the file preview, mirrored from the baseline.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/FilesPage.swift` (read line by
// line; every section, row, control and string below names the lines it copies).
// The page is the baseline's `FilesPage` + `FilePreviewPage`: the listing is one
// `Section(fileGroupTitle)` whose rows are the sub-folders followed by the files
// (`FilesPage.swift:115`–`:136`), and the preview is the sheet the file row opens
// (`:59`–`:64`, body `:290`–`:353`).
//
// What the baseline calls "empty" and what it calls "unreadable" are kept apart,
// because the baseline keeps them apart:
//   * an empty workspace (`model.files.isEmpty`, `:102`) is the two-line card
//     「还没有文件」/「智能体做的文件会出现在这里。」;
//   * an empty *sub-directory* is the section title with no rows — the baseline has
//     no "this folder is empty" sentence, so neither does this page;
//   * a file whose bytes cannot be read is the 「这个文件已经不在了。」 card, whose
//     description is the host's reason or 「请使用分享功能打开此文件。」 (`:316`).
// A host that has not reported the listing at all is *not* an empty workspace:
// [FilesScreenState.waiting] renders the waiting copy instead of claiming 0 files
// (the baseline's `model.files` is always a materialized array, so it has no such
// state; this is the Android host-snapshot gap, not a baseline behaviour).
//
// ScreenState: `FilesScreenState.from(source, local)` is a pure function of the
// host's read-only snapshot (`files`, the preview read) and the local navigation
// script (directory, query, previewed file). §3.1 rule 3 makes that snapshot the
// UiState-side input on a page with no harness event anchor, so the listing and
// the preview sequence are asserted on the JVM.
//
// Geometry: the page margin and the row floors are page-level tokens
// (`geometry.pageOuterMarginH`, `geometry.pageRowMinHeight`); the vertical inset of
// the preview's bottom bar has no page token, so it reuses `spacing.badgeInsetH`
// and says so at the call site. Nothing here invents a colour or a length.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * One entry of the workspace tree, as the host listed it.
 *
 * @param id the host's stable identity (a row key, never shown).
 * @param relativePath the path relative to the workspace root; the baseline keeps
 *   it and derives the name and the folder from it (`FilesPage.swift:192`,
 *   `:217`), so this page does the same instead of trusting two more host fields.
 * @param size the byte count; `null` when the host did not measure it, which the
 *   row shows as [UiStrings.UNKNOWN] rather than as 0.
 */
@Immutable
public data class WorkspaceFile(
    public val id: String,
    public val relativePath: String,
    public val size: Long? = null,
)

/**
 * Which of the baseline's preview bodies a path takes.
 *
 * The baseline decides by extension, in this order (`FilesPage.swift:284`–`:288`,
 * `:361`–`:362`): HTML pages render in a page surface, Markdown in a Markdown
 * body, the listed text extensions through a text read, and everything else
 * through Quick Look. The order matters: `html` is also in the text-extension
 * list, but the HTML branch wins.
 */
public enum class FileKind {
    /** `html` / `htm`: a page surface, rooted at the owning workspace. */
    HTML,

    /** `md` / `markdown`: a Markdown body. */
    MARKDOWN,

    /** One of the listed text extensions: a monospaced, selectable text body. */
    TEXT,

    /** Everything else: Quick Look on iOS (images, PDF, Office, archives). */
    EXTERNAL,
}

/** The baseline's three extension sets, kept in one place so a test can pin them. */
private val HTML_EXTENSIONS: Set<String> = setOf("html", "htm")
private val MARKDOWN_EXTENSIONS: Set<String> = setOf("md", "markdown")

/**
 * `FilesPage.swift:286`–`:288`: the extensions the baseline treats as text, plus
 * the four Android-toolchain extensions (`kt`, `kts`, `java`, `gradle`).
 *
 * The baseline list is an Apple workspace's list; an Android host's workspace is
 * produced by the Kotlin/JVM/Gradle toolchain, so a verbatim copy would render
 * its main source files (`Main.kt`, `build.gradle`) as a binary card. The
 * addition is registered as `platform.workspace-text-extensions` in
 * `spec/platform/whitelist.json`; it changes which files take the text body and
 * nothing else — the preview caps, the path check and the share fallback stay
 * identical.
 */
private val TEXT_EXTENSIONS: Set<String> = setOf(
    "txt", "md", "markdown", "json", "yaml", "yml", "xml", "html", "htm", "csv", "tsv", "log",
    "swift", "py", "js", "ts", "sh", "toml", "ini", "patch", "diff", "css", "c", "h", "go", "rs",
    // Android toolchain (platform.workspace-text-extensions).
    "kt", "kts", "java", "gradle",
)

/**
 * Classifies a workspace path into the baseline's preview body.
 *
 * Pure and locale-free; the extension is lower-cased exactly like
 * `URL.pathExtension.lowercased()` in the baseline.
 */
public fun classifyFileKind(relativePath: String): FileKind {
    val name = relativePath.substringAfterLast('/')
    val dot = name.lastIndexOf('.')
    // A leading-dot file (".env") has an empty extension in Foundation, which
    // lands in the Quick Look branch, not the text one.
    val extension = if (dot <= 0) "" else name.substring(dot + 1).lowercase()
    return when {
        extension in HTML_EXTENSIONS -> FileKind.HTML
        extension in MARKDOWN_EXTENSIONS -> FileKind.MARKDOWN
        extension in TEXT_EXTENSIONS -> FileKind.TEXT
        else -> FileKind.EXTERNAL
    }
}

/**
 * What a read returned for the file being previewed.
 *
 * The host decides text vs binary (use [classifyFileContent] for a byte read);
 * the page never re-decodes a payload and never renders bytes it could not
 * decode.
 */
public sealed interface FileContentView {
    /** Decodable text; [truncated] is the host's own "I stopped reading" flag. */
    public data class Text(
        public val content: String,
        public val truncated: Boolean = false,
    ) : FileContentView

    /** Not text; [byteCount] may be `null` when the host did not measure it. */
    public data class Binary(public val byteCount: Long? = null) : FileContentView

    /** The host could not read it; [reason] may be `null`. */
    public data class Unreadable(public val reason: String? = null) : FileContentView
}

/**
 * One preview read, with the facts the baseline's `loadPreview` turns into copy.
 *
 * Every flag below names the baseline line that raises it; the page composes the
 * sentence itself so the copy stays in [UiStrings] instead of arriving as an
 * already-formatted host string.
 *
 * @param error the host's failure reason; `null` when the read succeeded.
 * @param content the decoded text (`FileKind.TEXT` / [FileKind.MARKDOWN]).
 * @param byteCount the measured size of a non-text file.
 * @param directTextTruncated `FilesPage.swift:379`: the 8 MiB direct read stopped.
 * @param textTruncated `:409`: the 256 KiB Worker read stopped.
 * @param linesTruncated `:412`: the Worker returned `eof = false` (200 lines).
 * @param materializedCopy `:420`–`:422`: the Worker read failed and the page fell
 *   back to the on-disk copy, which the bottom bar must say.
 * @param pageAvailable `FilesPage.swift:298`: `pageEntry` and `pageResolver` both
 *   resolved, i.e. the page has a real workspace origin.
 * @param sessionMissing `FilesPage.swift:356`–`:359`: there is no current session,
 *   so the baseline cannot read the session workspace at all.
 * @param unsafe `FilesPage.swift:366`–`:367` / `:391`: the file is outside the safe,
 *   materialized workspace snapshot, so the baseline refuses to open it.
 * @param shareable `FilesPage.swift:327` / `:343`: `safeFileURL != nil`. `null`
 *   means the host did not say, and the page then neither offers 分享 nor claims
 *   the file is gone.
 */
@Immutable
public data class FilePreviewRead(
    public val error: String? = null,
    public val content: String? = null,
    public val byteCount: Long? = null,
    public val directTextTruncated: Boolean = false,
    public val textTruncated: Boolean = false,
    public val linesTruncated: Boolean = false,
    public val materializedCopy: Boolean = false,
    public val pageAvailable: Boolean = false,
    public val sessionMissing: Boolean = false,
    public val unsafe: Boolean = false,
    public val shareable: Boolean? = null,
)

/**
 * The page's read-only input.
 *
 * @param files every file of the workspace (`ChatModel.files`); `null` means the
 *   host has not reported the listing, which is the waiting state, not an empty
 *   workspace.
 * @param preview the read of [FilesLocalState.previewPath]; `null` while the read
 *   is in flight.
 */
@Immutable
public data class FilesSource(
    public val files: List<WorkspaceFile>? = null,
    public val preview: FilePreviewRead? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/** What the preview body shows; one case per baseline `if` (`FilesPage.swift:290`). */
public sealed interface FilePreview {
    /** No preview: the listing is on screen. */
    public data object Hidden : FilePreview

    /** A text/markdown body: the monospaced, selectable text (`:307`–`:314`). */
    public data class Text(public val name: String, public val content: String) : FilePreview

    /**
     * An HTML page.
     *
     * @param available `:298`: the file belongs to a workspace, so the page can be
     *   rendered against a real origin; `false` is the baseline's
     *   「这个页面不在任何工作区里」 card (`:303`).
     */
    public data class Page(public val name: String, public val available: Boolean) : FilePreview

    /** A non-text file: Quick Look on iOS (`:297`), the degradation card here. */
    public data class External(public val name: String, public val byteCount: Long?) : FilePreview

    /** The read failed (`:316`); [reason] is the host's reason or `null`. */
    public data class Unavailable(public val name: String, public val reason: String?) : FilePreview
}

/** The previewed file's display name. */
public val FilePreview.name: String
    get() = when (this) {
        FilePreview.Hidden -> ""
        is FilePreview.Text -> name
        is FilePreview.Page -> name
        is FilePreview.External -> name
        is FilePreview.Unavailable -> name
    }

/**
 * The complete files screen state.
 *
 * @param groupTitle the section title: the current folder's name, or
 *   「手机工作区」 at the root (`FilesPage.swift:19`–`:23`).
 * @param directory the current directory relative to the workspace root, with a
 *   trailing `/` except at the root (the baseline's `directory`).
 * @param query the search text (`:56`).
 * @param folders the immediate sub-folders, sorted; empty while searching (`:39`).
 * @param files the current directory's files, in the host's order (`:31`).
 * @param waiting the host has not reported the listing (Android host gap).
 * @param workspaceEmpty the host reported a workspace with no files at all
 *   (`:102`); the two-line card replaces the section.
 * @param preview the body on top of the listing.
 * @param previewNotice the bottom bar's sentence (`:335`), already combined in
 *   the baseline's order.
 * @param shareable `FilesPage.swift:327`: whether 分享 is offered; `null` unknown.
 */
@Immutable
public data class FilesScreenState(
    public val groupTitle: String = UiStrings.FILES_WORKSPACE,
    public val directory: String = "",
    public val query: String = "",
    public val folders: List<String> = emptyList(),
    public val files: List<WorkspaceFile> = emptyList(),
    public val waiting: Boolean = true,
    public val workspaceEmpty: Boolean = false,
    public val preview: FilePreview = FilePreview.Hidden,
    public val previewNotice: String? = null,
    public val shareable: Boolean? = null,
) {
    /** True while the preview sub-page is on top of the listing. */
    public val isPreviewing: Boolean get() = preview != FilePreview.Hidden

    /** True when the current directory is below the workspace root. */
    public val canNavigateUp: Boolean get() = directory.isNotEmpty()

    /** True when the section has no rows: the baseline draws the header alone. */
    public val sectionEmpty: Boolean get() = folders.isEmpty() && files.isEmpty()

    public companion object {
        /**
         * Projects (host snapshot, local navigation script) into the screen state.
         *
         * Pure: the same snapshot and script always yield the same rows. `folders`
         * and `files` are derived exactly like the baseline's computed properties:
         * a path under [FilesLocalState.directory] whose tail has no `/` is a file
         * of this directory, and a tail with one contributes its first segment to
         * `folders`.
         */
        public fun from(
            source: FilesSource,
            local: FilesLocalState = FilesLocalState(),
        ): FilesScreenState {
            val all = source.files
            val directory = local.directory
            val query = local.query
            val previewPath = local.previewPath
            val read = source.preview

            // `FilesPage.swift:31`: children of the current directory, filtered by
            // the search text only when there is one.
            val files = all.orEmpty()
                .filter { file ->
                    file.relativePath.startsWith(directory) &&
                        file.relativePath.drop(directory.length).let { tail ->
                            if (query.isEmpty()) !tail.contains('/') else tail.contains(query, ignoreCase = true)
                        }
                }
            // `FilesPage.swift:39`: folders disappear while searching, and only the
            // first path segment counts (no recursion).
            val folders = if (query.isNotEmpty()) {
                emptyList()
            } else {
                all.orEmpty()
                    .mapNotNull { file ->
                        if (!file.relativePath.startsWith(directory)) return@mapNotNull null
                        val tail = file.relativePath.drop(directory.length)
                        val slash = tail.indexOf('/')
                        if (slash < 0) null else tail.substring(0, slash)
                    }
                    .distinct()
                    .sorted()
            }

            val kind = previewPath?.let(::classifyFileKind)
            val name = previewPath?.substringAfterLast('/').orEmpty()
            val preview = when {
                previewPath == null -> FilePreview.Hidden
                // `:290`–`:319`: the baseline's Group falls through to the
                // 「这个文件已经不在了。」 card until `loadPreview` answers, for every
                // kind; there is no separate loading body.
                read == null -> FilePreview.Unavailable(name, null)
                // `:356`–`:359`: without a current session there is no workspace to
                // read, and the baseline's sentence names that, not the file.
                read.sessionMissing -> FilePreview.Unavailable(name, UiStrings.FILES_PREVIEW_NO_SESSION)
                // `:366`–`:367` / `:391`: outside the safe snapshot, the baseline
                // refuses the file and says why.
                read.unsafe -> FilePreview.Unavailable(name, UiStrings.FILES_PREVIEW_UNSAFE)
                // `:298`–`:304`: an HTML file is either a page or "not in any workspace".
                kind == FileKind.HTML -> FilePreview.Page(name, read.pageAvailable)
                // `:389`–`:398`: Quick Look, which the host owns on Android too.
                kind == FileKind.EXTERNAL && read.error == null ->
                    FilePreview.External(name, read.byteCount)
                // `:420`–`:422`: the Worker read failed and the on-disk copy is shown.
                read.materializedCopy -> FilePreview.Text(name, read.content.orEmpty())
                // `:385` / `:424`: `读取文件失败：<host reason>`.
                read.error != null ->
                    FilePreview.Unavailable(name, UiStrings.FILES_PREVIEW_READ_FAILED.format(read.error))
                else -> FilePreview.Text(name, read.content.orEmpty())
            }
            // The bottom bar's sentence is composed here so the copy stays in
            // `UiStrings`; an unanswered read raises none (the baseline sets these
            // inside `loadPreview`).
            val notices = if (read == null) {
                emptyList()
            } else {
                buildList {
                    // `:364`: an HTML page always says where it runs.
                    if (kind == FileKind.HTML) add(UiStrings.FILES_PREVIEW_NOTICE_HTML)
                    if (read.directTextTruncated) add(UiStrings.FILES_PREVIEW_NOTICE_8MIB)
                    if (read.textTruncated) add(UiStrings.FILES_PREVIEW_NOTICE_256KIB)
                    if (read.linesTruncated) {
                        add(UiStrings.FILES_PREVIEW_NOTICE_LINES.format(INLINE_TEXT_PREVIEW_LINES))
                    }
                    if (read.materializedCopy) add(UiStrings.FILES_PREVIEW_NOTICE_COPY)
                }
            }

            return FilesScreenState(
                groupTitle = groupTitle(directory),
                directory = directory,
                query = query,
                folders = folders,
                files = files,
                waiting = all == null,
                workspaceEmpty = all != null && all.isEmpty(),
                preview = preview,
                previewNotice = notices.takeIf { it.isNotEmpty() }?.joinToString(" "),
                shareable = read?.shareable,
            )
        }

        /**
         * The section title (`FilesPage.swift:19`–`:23`): the last segment of the
         * current directory, or 「手机工作区」 at the root. The disk name
         * (`default-workspace`) never reaches the screen.
         */
        public fun groupTitle(directory: String): String {
            val trimmed = directory.trim('/')
            if (trimmed.isEmpty()) return UiStrings.FILES_WORKSPACE
            return trimmed.substringAfterLast('/').ifEmpty { UiStrings.FILES_WORKSPACE }
        }
    }
}

/** The baseline's inline text cap, restated so the notice sentence stays true. */
private const val INLINE_TEXT_PREVIEW_LINES: Int = 200

/** Decimal units for [formatFileSize], matching `ByteCountFormatter`'s `.file` style. */
private const val DECIMAL_UNIT: Long = 1000
private const val TEN: Long = 10
private const val THOUSAND_TENTHS: Long = 10_000
private val DECIMAL_UNITS: List<String> = listOf("KB", "MB", "GB", "TB")

/**
 * Classifies a byte read as text or binary without inventing an encoding.
 *
 * A NUL byte or an invalid UTF-8 sequence means "this is not text"; a decodable
 * payload becomes a text preview. Pure (no clock, no I/O).
 */
public fun classifyFileContent(bytes: ByteArray): FileContentView {
    if (bytes.isEmpty()) return FileContentView.Text("")
    if (bytes.any { it == NUL }) return FileContentView.Binary(bytes.size.toLong())
    val decoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
    return try {
        FileContentView.Text(decoder.decode(ByteBuffer.wrap(bytes)).toString())
    } catch (_: CharacterCodingException) {
        // Every byte was still measured; only the text rendering is unavailable.
        FileContentView.Binary(bytes.size.toLong())
    }
}

/**
 * Formats a byte count the way the baseline's `ByteCountFormatter` renders a file
 * size (`countStyle: .file`): decimal units, at most three significant digits, and
 * Foundation's own unit words.
 *
 * This is deliberately a second formatter next to [formatByteSize], not a flag on
 * it: the two answer different questions.
 *
 *  * [formatByteSize] renders a *technical budget* in binary units, because
 *    `spec/v1/budgets.md` §4 fixes `MB`/`MiB` at 1 048 576 bytes and a label has
 *    to match the base the number was computed with (memory pages, budgets, logs).
 *  * this function renders a *file size for a person* exactly as the iOS screen
 *    shows it. The same file must not read `2 KB` on the phone and `1.5 KiB` on
 *    the other; that is the visible difference the mirror exists to remove.
 *
 * Where each one is used, so a reader never has to guess which system a number
 * belongs to: file sizes (the files page's rows and its binary card, and the
 * shell page's 输出上限 / 单文件上限) come from this decimal function; technical
 * budgets (memory, per-turn network volume, the budgets page and logs) come from
 * [formatByteSize]'s binary units. Seeing both on one device is deliberate, and
 * a page that mixes them is a bug.
 *
 * The rounding rules are pinned by tests against a Foundation probe (`swift -e`
 * with `ByteCountFormatter`, zh_CN): zero prints `Zero KB`; below 1 000 bytes the
 * word is `byte`/`bytes`; KB is always whole; MB and above keep one decimal below
 * ten and drop it from ten up; a value that rounds up to 1 000 of its unit
 * promotes to the next one (`999 999 B` → `1 MB`, `999 999 999 B` → `1 GB`).
 */
public fun formatFileSize(bytes: Long): String {
    require(bytes >= 0) { "a byte count is never negative" }
    if (bytes == 0L) return "Zero KB"
    if (bytes < DECIMAL_UNIT) return if (bytes == 1L) "1 byte" else "$bytes bytes"
    var unit = 0
    var divisor = DECIMAL_UNIT
    while (unit < DECIMAL_UNITS.lastIndex && bytes / divisor >= DECIMAL_UNIT) {
        divisor *= DECIMAL_UNIT
        unit += 1
    }
    while (true) {
        // A whole-unit round for KB; one decimal below ten for MB and above, a
        // whole number from ten up. `tenths` is the value in tenths of the unit.
        val tenths = when {
            unit == 0 -> roundWholeUnits(bytes, divisor) * 10
            bytes < TEN * divisor -> roundTenths(bytes, divisor)
            else -> roundTenths(bytes, divisor) / 10 * 10
        }
        if (tenths >= THOUSAND_TENTHS && unit < DECIMAL_UNITS.lastIndex) {
            unit += 1
            divisor *= DECIMAL_UNIT
            continue
        }
        val whole = tenths / 10
        val fraction = tenths % 10
        val label = if (fraction == 0L) "$whole ${DECIMAL_UNITS[unit]}" else "$whole.$fraction ${DECIMAL_UNITS[unit]}"
        return label
    }
}

/** Rounds `bytes / divisor` to tenths of the unit, half away from zero. */
private fun roundTenths(bytes: Long, divisor: Long): Long =
    (bytes * 10 + divisor / 2) / divisor

/** Rounds `bytes / divisor` to whole units, half away from zero. */
private fun roundWholeUnits(bytes: Long, divisor: Long): Long =
    (bytes + divisor / 2) / divisor

/** The local UI events of the files page. */
public sealed interface FilesUiEvent {
    /** Enter a sub-folder: the baseline pushes a page with `directory + name + "/"`. */
    public data class OpenFolder(public val name: String) : FilesUiEvent

    /** Pop one directory (`FilesPage.swift:117`–`:122` pushes; the stack pops). */
    public data object NavigateUp : FilesUiEvent

    /** Open a file: the baseline always shows the preview (`:125`–`:134`). */
    public data class OpenFile(public val relativePath: String) : FilesUiEvent

    /** Leave the preview (`完成`, `:324`). */
    public data object ClosePreview : FilesUiEvent

    /** The search field changed (`:56`). */
    public data class SetQuery(public val query: String) : FilesUiEvent
}

/**
 * The local script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param directory the current directory (the baseline's `@State directory`).
 * @param query the search text.
 * @param previewPath the file whose preview is on top; `null` for the listing.
 */
@Immutable
public data class FilesLocalState(
    public val directory: String = "",
    public val query: String = "",
    public val previewPath: String? = null,
) {
    /** Applies one local event. */
    public fun apply(event: FilesUiEvent): FilesLocalState = when (event) {
        is FilesUiEvent.OpenFolder ->
            // A pushed FilesPage starts with an empty query (`:25`) and no preview.
            copy(
                directory = directory + event.name.trim('/') + "/",
                query = "",
                previewPath = null,
            )
        FilesUiEvent.NavigateUp -> copy(directory = parentOf(directory), previewPath = null)
        is FilesUiEvent.OpenFile -> copy(previewPath = event.relativePath)
        FilesUiEvent.ClosePreview -> copy(previewPath = null)
        is FilesUiEvent.SetQuery -> copy(query = event.query)
    }

    private fun parentOf(path: String): String {
        val trimmed = path.trimEnd('/')
        val slash = trimmed.lastIndexOf('/')
        return if (slash < 0) "" else trimmed.substring(0, slash + 1)
    }
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The files screen.
 *
 * @param state the pure screen state ([FilesScreenState.from]).
 * @param onOpenFolder enter a sub-folder (`:117`).
 * @param onOpenFile open a file's preview (`:125`).
 * @param onQueryChange the search text changed (`:56`).
 * @param onNavigateUp go to the parent directory (the baseline's back button).
 * @param onClosePreview close the preview (`完成`, `:324`).
 * @param onBack leave the page.
 * @param onShare share the previewed file (`:328`, the `share-sheet` row of
 *   `spec/ui/v1/README.md` §5).
 * @param onOpenDemo the toolbar's 「3D 示例」 (`:79`–`:86`); `null` hides it.
 * @param pageSurface the host's WebView for an HTML preview (`:301`); the surface
 *   is host-owned exactly like `WebSurfacePage`'s.
 */
@Composable
public fun FilesPage(
    state: FilesScreenState,
    onOpenFolder: (String) -> Unit,
    onOpenFile: (WorkspaceFile) -> Unit,
    onQueryChange: (String) -> Unit,
    onNavigateUp: () -> Unit,
    onClosePreview: () -> Unit,
    onBack: () -> Unit,
    onShare: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenDemo: (() -> Unit)? = null,
    pageSurface: (@Composable () -> Unit)? = null,
) {
    val previewing = state.isPreviewing
    // back-gesture (§5): the preview is one level deeper than the listing and a
    // sub-directory one level below its parent, so the header's back walks the same
    // stack the baseline's NavigationStack walks.
    val onHeaderBack = when {
        previewing -> onClosePreview
        state.canNavigateUp -> onNavigateUp
        else -> onBack
    }

    PageFrame(
        title = if (previewing) state.preview.name else state.groupTitle,
        onBack = onHeaderBack,
        rootTag = UiPageTags.FILES_ROOT,
        modifier = modifier,
        actions = {
            if (previewing) {
                if (state.shareable == true) {
                    PreviewAction(
                        label = UiStrings.FILES_PREVIEW_SHARE,
                        tag = UiPageTags.FILES_PREVIEW_SHARE,
                        onClick = onShare,
                    )
                }
                PreviewAction(
                    label = UiStrings.FILES_PREVIEW_DONE,
                    tag = UiPageTags.FILES_PREVIEW_DONE,
                    onClick = onClosePreview,
                )
            } else if (onOpenDemo != null) {
                PreviewAction(
                    label = UiStrings.FILES_DEMO,
                    tag = UiPageTags.FILES_DEMO,
                    onClick = onOpenDemo,
                    description = UiStrings.FILES_DEMO_OPEN,
                )
            }
        },
    ) {
        if (previewing) {
            PreviewBody(
                state = state,
                pageSurface = pageSurface,
            )
        } else {
            ListingBody(
                state = state,
                onOpenFolder = onOpenFolder,
                onOpenFile = onOpenFile,
                onQueryChange = onQueryChange,
            )
        }
    }
}

/** The listing: the search field above the one section (`FilesPage.swift:100`). */
@Composable
private fun ListingBody(
    state: FilesScreenState,
    onOpenFolder: (String) -> Unit,
    onOpenFile: (WorkspaceFile) -> Unit,
    onQueryChange: (String) -> Unit,
) {
    Column(modifier = Modifier.fillMaxSize()) {
        SearchField(query = state.query, onQueryChange = onQueryChange)
        when {
            // A host that has not reported the listing: waiting, not "no files".
            state.waiting -> EmptyHint(
                title = UiStrings.WAITING_ENGINE,
                hint = null,
                tag = UiTags.FILES_EMPTY,
            )

            // `:102`–`:113`: the whole workspace has no file; the baseline's card
            // is a List row, not a Section.
            state.workspaceEmpty -> NoFilesCard()

            // `:115`–`:136`: one section, folders first, then the files. When both
            // are empty the baseline still draws the section title, so this does
            // too (`sectionEmpty`).
            else -> LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .testTag(UiTags.FILES_LIST),
            ) {
                item(key = "section") {
                    SessionSectionLabel(
                        text = state.groupTitle,
                        modifier = Modifier
                            .testTag(UiPageTags.FILES_SECTION)
                            .semantics { heading() },
                    )
                }
                items(items = state.folders, key = { "folder.$it" }) { folder ->
                    FolderRow(folder = folder, onOpenFolder = onOpenFolder)
                }
                items(items = state.files, key = { "file.${it.id}" }) { file ->
                    FileRow(file = file, onOpenFile = onOpenFile)
                }
            }
        }
    }
}

/** 「搜索文件」 (`FilesPage.swift:56`): a plain field, so no new control is invented. */
@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = type.body.copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            // Page-level geometry: the search row is a page row and uses its floor.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .testTag(UiPageTags.FILES_SEARCH)
            .semantics { contentDescription = UiStrings.FILES_SEARCH },
        decorationBox = { inner ->
            if (query.isEmpty()) {
                BasicText(
                    text = UiStrings.FILES_SEARCH,
                    style = type.body.copy(color = tokens.colors.tertiary),
                )
            }
            inner()
        },
    )
}

/** 「还没有文件」 + 「智能体做的文件会出现在这里。」 (`FilesPage.swift:103`–`:113`). */
@Composable
private fun NoFilesCard() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.FILES_NONE)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.FILES_NONE,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.FILES_NONE_HINT,
            style = type.secondary.copy(
                color = tokens.colors.secondary,
                textAlign = TextAlign.Center,
            ),
        )
    }
}

/** A sub-folder row: the baseline's `Label(folder, systemImage: "folder")` (`:120`). */
@Composable
private fun FolderRow(folder: String, onOpenFolder: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.FILES_FOLDER_ROW)
            .clickable(role = Role.Button, onClick = { onOpenFolder(folder) })
            // Page-level geometry: a folder row is a page row (`minHeight: 44`, `:121`).
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = folder },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = folder,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        BasicText(
            text = CHEVRON,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/**
 * One file row (`FilesPage.swift:184`–`:222`): name, then the folder it lives in,
 * then the size, then a chevron. The full relative path never reaches the screen
 * (`:215`): only the last two segments do.
 */
@Composable
private fun FileRow(file: WorkspaceFile, onOpenFile: (WorkspaceFile) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val folder = folderName(file.relativePath)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.FILES_FILE_ROW)
            .clickable(role = Role.Button, onClick = { onOpenFile(file) })
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = fileName(file.relativePath) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = fileName(file.relativePath),
                style = type.body.copy(color = tokens.colors.primary),
                maxLines = 1,
            )
            if (folder != null) {
                BasicText(
                    text = folder,
                    style = type.caption.copy(color = tokens.colors.secondary),
                    maxLines = 1,
                )
            }
            BasicText(
                // A measured size, or 未知: never a rounded guess.
                text = file.size?.let { formatFileSize(it) } ?: UiStrings.UNKNOWN,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
        BasicText(
            text = CHEVRON,
            style = type.caption.copy(color = tokens.colors.tertiary),
        )
    }
}

/**
 * The preview body (`FilesPage.swift:290`–`:320`), plus the bottom bar (`:335`).
 *
 * The baseline's first frame — before `loadPreview` answers — is its
 * `ContentUnavailableView` 「这个文件已经不在了。」, so an unanswered read renders the
 * same card; there is no separate loading sentence in the baseline and none is
 * invented here.
 */
@Composable
private fun PreviewBody(
    state: FilesScreenState,
    pageSurface: (@Composable () -> Unit)?,
) {
    val preview = state.preview
    Column(modifier = Modifier.fillMaxSize().testTag(UiTags.FILES_PREVIEW)) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (preview) {
                FilePreview.Hidden -> Unit

                // `:307`–`:314`: monospaced, selectable, both axes scroll.
                is FilePreview.Text -> TextPreview(content = preview.content)

                is FilePreview.Page -> {
                    if (preview.available) {
                        // `:301`: the page runs against a real workspace origin; the
                        // WebView itself is the host's (same split as WebSurfacePage).
                        Box(modifier = Modifier.fillMaxSize().testTag(UiPageTags.FILES_PREVIEW_SURFACE)) {
                            pageSurface?.invoke()
                        }
                    } else {
                        // `:303`–`:304`: an HTML file that belongs to no workspace.
                        UnavailableCard(
                            title = UiStrings.FILES_PREVIEW_OUTSIDE,
                            description = UiStrings.FILES_PREVIEW_OUTSIDE_HINT,
                            tag = UiPageTags.FILES_PREVIEW_CARD,
                        )
                    }
                }

                // `:292`–`:297`: Quick Look opens images/PDF/Office; the host owns
                // that on Android, and the page states the measured facts only.
                is FilePreview.External -> UnavailableCard(
                    title = UiStrings.FILES_PREVIEW_BINARY,
                    description = UiStrings.FILES_PREVIEW_BINARY_HINT,
                    detail = preview.byteCount?.let { formatFileSize(it) } ?: UiStrings.UNKNOWN,
                    tag = UiPageTags.FILES_PREVIEW_CARD,
                )

                // `:316`–`:317`: the failure, with the host's reason or the baseline's
                // sentence.
                is FilePreview.Unavailable -> UnavailableCard(
                    title = UiStrings.FILES_PREVIEW_GONE,
                    description = preview.reason ?: UiStrings.FILES_PREVIEW_GONE_HINT,
                    tag = UiPageTags.FILES_PREVIEW_CARD,
                )
            }
        }
        // `:335`–`:350`: the notice wins; otherwise an un-shareable file says so.
        val notice = state.previewNotice
        when {
            notice != null -> PreviewBottomBar(
                text = notice,
                tag = UiPageTags.FILES_PREVIEW_NOTICE,
            )
            state.shareable == false -> PreviewBottomBar(
                text = UiStrings.FILES_PREVIEW_MISSING,
                tag = UiPageTags.FILES_PREVIEW_MISSING,
            )
        }
    }
}

/** The text body: the baseline's `ScrollView([.vertical, .horizontal])` (`:308`). */
@Composable
private fun TextPreview(content: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .horizontalScroll(rememberScrollState())
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    ) {
        BasicText(
            text = content,
            style = type.code.copy(color = tokens.colors.primary),
            modifier = Modifier.testTag(UiPageTags.FILES_PREVIEW_TEXT),
        )
    }
}

/** A `ContentUnavailableView` (`:303`, `:316`): a title, a description, an optional fact. */
@Composable
private fun UnavailableCard(
    title: String,
    description: String,
    tag: String,
    detail: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = title,
            style = type.headline.copy(
                color = tokens.colors.primary,
                textAlign = TextAlign.Center,
            ),
        )
        BasicText(
            text = description,
            style = type.secondary.copy(
                color = tokens.colors.secondary,
                textAlign = TextAlign.Center,
            ),
        )
        if (detail != null) {
            BasicText(
                text = detail,
                style = type.caption.copy(color = tokens.colors.tertiary),
            )
        }
    }
}

/** The bottom bar (`:335`–`:350`): a footnote line on the chrome's own fill. */
@Composable
private fun PreviewBottomBar(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            // unverified geometry: the spec declares no page-level token for the
            // bottom bar's inset; the badge's horizontal inset (10) is reused.
            .padding(vertical = tokens.spacing.badgeInsetH)
            .background(tokens.colors.selector)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
    )
}

/** A header text action; the page never draws a bar button it cannot label. */
@Composable
private fun PreviewAction(
    label: String,
    tag: String,
    onClick: () -> Unit,
    description: String = label,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = label,
        style = type.secondary.copy(color = tokens.colors.accent),
        maxLines = 1,
        modifier = Modifier
            .testTag(tag)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .padding(tokens.spacing.iconText),
    )
}

/** The last path segment (`URL.lastPathComponent`). */
private fun fileName(relativePath: String): String =
    relativePath.substringAfterLast('/').ifEmpty { relativePath }

/**
 * The parent folder's name, or `null` at the workspace root
 * (`FilesPage.swift:216`–`:220`).
 */
private fun folderName(relativePath: String): String? {
    val parent = relativePath.trimEnd('/').substringBeforeLast('/', missingDelimiterValue = "")
    if (parent.isEmpty() || parent == "." || parent == "/") return null
    return parent.substringAfterLast('/').ifEmpty { null }
}

/** The disclosure glyph the listing's rows end with (the baseline's chevron). */
private const val CHEVRON: String = "›"

private val NUL: Byte = 0.toByte()

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object FilesPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_H,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
