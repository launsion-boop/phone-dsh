// Files: the workspace browser, mirrored from the baseline's `FilesPage` listing.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/FilesPage.swift` (read line by
// line; every section, row, control and string below names the lines it copies).
// The page is the baseline's listing: one `Section(fileGroupTitle)` whose rows are
// the sub-folders followed by the files (`FilesPage.swift:115`–`:136`), the search
// field, and the optional 「3D 示例」 toolbar entry.
//
// PR #15 (`8dd17496`) deleted `FilePreviewPage` and moved the preview into the
// standalone `PreviewSurface`; a file row now pushes `PdshRoute.Preview` and one
// back returns to this listing (`FilesPage.swift:59`; `PdshNavHost.kt:632` hands
// the row to the route). The in-page preview that mirrored `FilePreviewPage` is
// gone with it: this route never supplied the preview read, so every preview branch
// was unreachable, and the one preview face's contract is
// `spec/ui/v1/pages/preview-surface.json`.
//
// What the baseline calls "empty" and what it calls "unreadable" are kept apart,
// because the baseline keeps them apart:
//   * an empty workspace (`model.files.isEmpty`, `:102`) is the two-line card
//     「还没有文件」/「智能体做的文件会出现在这里。」;
//   * an empty *sub-directory* is the section title with no rows — the baseline has
//     no "this folder is empty" sentence, so neither does this page.
// A host that has not reported the listing at all is *not* an empty workspace:
// [FilesScreenState.waiting] renders the waiting copy instead of claiming 0 files
// (the baseline's `model.files` is always a materialized array, so it has no such
// state; this is the Android host-snapshot gap, not a baseline behaviour).
//
// ScreenState: `FilesScreenState.from(source, local)` is a pure function of the
// host's read-only snapshot (`files`) and the local navigation script (directory,
// query). §3.1 rule 3 makes that snapshot the UiState-side input on a page with no
// harness event anchor, so the listing and the folder sequence are asserted on the JVM.
//
// Geometry: page margins and 48pt touch rows use HomeMetrics; icons use PdshIcons.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.surface.PageBarCapsule
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
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
 * Which of the preview surface's bodies a path takes.
 *
 * The baseline decides by extension, in this order (`FilesPage.swift:284`–`:288`,
 * `:361`–`:362` of the pre-PR15 file; `PreviewSurface.swift:66` keeps the same
 * order): HTML pages render in a page surface, Markdown in a Markdown body, the
 * listed text extensions through a text read, and everything else through Quick
 * Look. The order matters: `html` is also in the text-extension list, but the HTML
 * branch wins. `PreviewPathResolver`/`PreviewKind` reuse this classifier, so it
 * stays in the page layer instead of being copied into the preview surface.
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

/** Host receipt for a document-picker request; cancellation is a completed answer. */
public enum class FilesImportReceipt {
    CANCELLED,
    IMPORTED,
    FAILED,
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
 * nothing else.
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
 * The page's read-only input.
 *
 * @param files every file of the workspace (`ChatModel.files`); `null` means the
 *   host has not reported the listing, which is the waiting state, not an empty
 *   workspace.
 */
@Immutable
public data class FilesSource(
    public val files: List<WorkspaceFile>? = null,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

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
    public val importReceipt: FilesImportReceipt? = null,
) {
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
            importReceipt: FilesImportReceipt? = null,
        ): FilesScreenState {
            val all = source.files
            val directory = local.directory
            val query = local.query

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

            return FilesScreenState(
                groupTitle = groupTitle(directory),
                directory = directory,
                query = query,
                folders = folders,
                files = files,
                waiting = all == null,
                workspaceEmpty = all != null && all.isEmpty(),
                importReceipt = importReceipt,
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

    /** The search field changed (`:56`). */
    public data class SetQuery(public val query: String) : FilesUiEvent
}

/**
 * The local script; [apply] is pure, so a test drives it like a reducer.
 *
 * @param directory the current directory (the baseline's `@State directory`).
 * @param query the search text.
 */
@Immutable
public data class FilesLocalState(
    public val directory: String = "",
    public val query: String = "",
) {
    /** Applies one local event. */
    public fun apply(event: FilesUiEvent): FilesLocalState = when (event) {
        is FilesUiEvent.OpenFolder ->
            // A pushed FilesPage starts with an empty query (`:25`).
            copy(
                directory = directory + event.name.trim('/') + "/",
                query = "",
            )
        FilesUiEvent.NavigateUp -> copy(directory = parentOf(directory))
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
 * @param onOpenFile open a file: the files route hands the row to `PdshRoute.Preview`
 *   and one back returns here (`:125`–`:134`, PR #15's push).
 * @param onQueryChange the search text changed (`:56`).
 * @param onNavigateUp go to the parent directory (the baseline's back button).
 * @param onBack leave the page.
 * @param onOpenDemo the toolbar's 「3D 示例」 (`:79`–`:86`). The entry is always
 *   drawn, because the baseline always draws it (`FilesPage.swift:79`): when the
 *   host supplies no demo surface the page opens its own sheet, so a null
 *   callback can no longer make a labelled control exist in the source and never
 *   render — the hole `page_structure_check.py` could not see. Since L75 the entry
 *   is drawn as the baseline's icon-only cube in a floating white pill rather than
 *   as a text verb: `Label(…, systemImage: "cube")` in a toolbar renders its icon
 *   alone, and `ios-files.png` shows exactly that (x 353.0–374.33, y 72.33–96.33).
 */
@Composable
public fun FilesPage(
    state: FilesScreenState,
    onOpenFolder: (String) -> Unit,
    onOpenFile: (WorkspaceFile) -> Unit,
    onQueryChange: (String) -> Unit,
    onNavigateUp: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenDemo: (() -> Unit)? = null,
    onImportRequest: (() -> Unit)? = null,
) {
    // back-gesture (§5): a sub-directory is one level below its parent, so the
    // header's back walks the same stack the baseline's NavigationStack walks.
    val onHeaderBack = if (state.canNavigateUp) onNavigateUp else onBack
    // The iOS page uses an inline navigation title. The viewer and document
    // picker remain host-owned seams; absent callbacks disable their controls.
    val tokens = LocalUiTokens.current
    SettingsSubPageFrame(
        title = state.groupTitle,
        onBack = onHeaderBack,
        backGlyph = PAGE_BACK_GLYPH,
        pageFill = true,
        rootTag = UiPageTags.FILES_ROOT,
        modifier = modifier,
        trailing = {
            Row(horizontalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV)) {
                PageBarCapsule(
                    description = FILES_IMPORT_LABEL,
                    onClick = { onImportRequest?.invoke() },
                    insetH = HomeMetrics.navButton / 4,
                    elevation = HomeMetrics.blockGap / 4,
                    showsLabel = true,
                    glyph = {
                        PdshIconView(
                            icon = PdshIcon.DOCUMENT,
                            size = HomeMetrics.navIcon,
                            tint = tokens.colors.textPrimary,
                            contentDescription = null,
                        )
                    },
                    enabled = onImportRequest != null,
                    tag = FILES_IMPORT_TEST_TAG,
                    accessibilityLabel = if (onImportRequest == null) FILES_IMPORT_UNAVAILABLE else FILES_IMPORT_LABEL,
                )
                PageBarCapsule(
                    description = UiStrings.FILES_DEMO,
                    onClick = { onOpenDemo?.invoke() },
                    insetH = HomeMetrics.navButton / 4,
                    elevation = HomeMetrics.blockGap / 4,
                    showsLabel = false,
                    glyph = {
                        PdshIconView(
                            icon = PdshIcon.PUZZLE,
                            size = HomeMetrics.navIcon,
                            tint = tokens.colors.textPrimary,
                            contentDescription = null,
                        )
                    },
                    enabled = onOpenDemo != null,
                    tag = UiPageTags.FILES_DEMO,
                    accessibilityLabel = if (onOpenDemo == null) FILES_DEMO_UNAVAILABLE else UiStrings.FILES_DEMO_OPEN,
                )
            }
        },
    ) {
        ListingBody(
            state = state,
            onOpenFolder = onOpenFolder,
            onOpenFile = onOpenFile,
            onQueryChange = onQueryChange,
            onImportUnavailable = onImportRequest == null,
        )
    }
}

/**
 * The 「3D 示例」 sheet (`FilesPage.swift:62`–`:75`).
 *
 * The native iOS viewer is not available in this Compose module. The toolbar
 * remains disabled until the host supplies a real viewer route.
 */
private const val FILES_IMPORT_LABEL = "导入文件"
private const val FILES_IMPORT_UNAVAILABLE = "导入文件，宿主未提供文档选择器"
private const val FILES_IMPORT_UNAVAILABLE_HINT = "当前宿主没有提供文件选择器，尚未导入文件。"
private const val FILES_IMPORT_CANCELLED = "文件导入已取消"
private const val FILES_IMPORT_COMPLETED = "文件已导入工作区"
private const val FILES_IMPORT_FAILED = "文件导入失败"
private const val FILES_DEMO_UNAVAILABLE = "3D 示例，宿主未提供本地页面查看器"
private const val FILES_IMPORT_TEST_TAG = "files-import"

/** The listing: the search field above the one section (`FilesPage.swift:100`). */
@Composable
private fun ListingBody(
    state: FilesScreenState,
    onOpenFolder: (String) -> Unit,
    onOpenFile: (WorkspaceFile) -> Unit,
    onQueryChange: (String) -> Unit,
    onImportUnavailable: Boolean,
) {
    // The search field is pinned at the top; the IME must shrink the list under it
    // instead of covering the last rows, which a no-op scroll cannot lift
    // (spec §5 row `insets`: the page consumes its IME inset, not the host).
    Column(modifier = Modifier.fillMaxSize().imePadding()) {
        SearchField(query = state.query, onQueryChange = onQueryChange)
        if (state.importReceipt != null) {
            ImportReceiptLine(
                when (state.importReceipt) {
                    FilesImportReceipt.CANCELLED -> FILES_IMPORT_CANCELLED
                    FilesImportReceipt.IMPORTED -> FILES_IMPORT_COMPLETED
                    FilesImportReceipt.FAILED -> FILES_IMPORT_FAILED
                },
            )
        } else if (onImportUnavailable) {
            ImportReceiptLine(FILES_IMPORT_UNAVAILABLE_HINT)
        }
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

@Composable
private fun ImportReceiptLine(message: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = message,
        style = type.caption.copy(color = tokens.colors.textSecondary),
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = HomeMetrics.contentInset, vertical = tokens.spacing.badgeInsetV)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}

/**
 * 「搜索文件」 (`FilesPage.swift:56`), drawn as the baseline's grey capsule.
 *
 * `ios-files.png` measures the field as a 40 pt capsule at x 16–385.7, fill
 * `#EFEFF0`, with a 20 pt magnifier before the placeholder. The token table has no
 * search-field token, so the capsule takes `colors.selector` (the closest surface
 * fill), the page row's 44 pt floor and the page margin; the shape is a capsule
 * (height/2), not a new length.
 */
@Composable
private fun SearchField(query: String, onQueryChange: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicTextField(
        value = query,
        onValueChange = onQueryChange,
        singleLine = true,
        textStyle = type.body.copy(color = tokens.colors.textPrimary),
        cursorBrush = SolidColor(tokens.colors.pageAccent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            // HomeSpec search pill uses a 48pt control row and 24pt radius.
            .clip(RoundedCornerShape(HomeMetrics.bubbleRadius))
            .background(tokens.colors.surface)
            .padding(horizontal = tokens.spacing.cardInset)
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .testTag(UiPageTags.FILES_SEARCH)
            .semantics { contentDescription = UiStrings.FILES_SEARCH },
        decorationBox = { inner ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                PdshIconView(
                    icon = PdshIcon.SEARCH,
                    size = HomeMetrics.navIcon,
                    tint = tokens.colors.textSecondary,
                    contentDescription = null,
                )
                Box(modifier = Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        BasicText(
                            text = UiStrings.FILES_SEARCH,
                            style = type.body.copy(color = tokens.colors.textTertiary),
                        )
                    }
                    inner()
                }
            }
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
                horizontal = HomeMetrics.contentInset,
                // `ios-files.png`: the search field ends at y 212.67 and the card's
                // title ink starts at 269.33 — a 56.7 pt gap, which is the card's own
                // 24 pt padding plus the list's 32 pt top inset. Android has no list
                // inset here (the card is the body), so the two are summed.
                vertical = tokens.spacing.cardInset * 2 + tokens.spacing.iconText * 4,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.FILES_NONE,
            style = type.pageTitle.copy(color = tokens.colors.textPrimary),
        )
        BasicText(
            text = UiStrings.FILES_NONE_HINT,
            style = type.listItem.copy(
                color = tokens.colors.textSecondary,
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
            // HomeSpec grouped rows use a 48pt minimum touch target.
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = folder },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        PdshIconView(
            icon = PdshIcon.FOLDER,
            size = HomeMetrics.navIcon,
            tint = tokens.colors.pageAccent,
            contentDescription = null,
        )
        BasicText(
            text = folder,
            style = type.body.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        PdshIconView(
            icon = PdshIcon.CHEVRON_RIGHT,
            size = HomeMetrics.navIcon * 3 / 4,
            tint = tokens.colors.textTertiary,
            contentDescription = null,
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
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.contentInset,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = fileName(file.relativePath) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        // Reserve one 44pt touch-height icon slot in the 48pt row.
        Box(
            modifier = Modifier.size(
                width = HomeMetrics.navButton,
                height = HomeMetrics.navButton,
            ),
            contentAlignment = Alignment.Center,
        ) {
            PdshIconView(
                icon = PdshIcon.DOCUMENT,
                size = HomeMetrics.navIcon,
                tint = tokens.colors.textTertiary,
                contentDescription = null,
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = fileName(file.relativePath),
                style = type.body.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
            )
            if (folder != null) {
                BasicText(
                    text = folder,
                    style = type.listItem.copy(color = tokens.colors.textSecondary),
                    maxLines = 1,
                )
            }
            BasicText(
                // A measured size, or 未知: never a rounded guess.
                text = file.size?.let { formatFileSize(it) } ?: UiStrings.UNKNOWN,
                style = type.listItem.copy(color = tokens.colors.textTertiary),
            )
        }
        PdshIconView(
            icon = PdshIcon.CHEVRON_RIGHT,
            size = HomeMetrics.navIcon * 3 / 4,
            tint = tokens.colors.textTertiary,
            contentDescription = null,
        )
    }
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

private val NUL: Byte = 0.toByte()

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object FilesPageTokens {
    val refs: List<String> = listOf(
        "colors.pageAccent",
        "colors.surface",
        "colors.textPrimary",
        "colors.textSecondary",
        "colors.textTertiary",
        "spacing.badgeInsetV",
        "spacing.cardInset",
        "spacing.iconText",
        "typography.body",
        "typography.caption",
        "typography.listItem",
        "typography.pageTitle",
    )
}
