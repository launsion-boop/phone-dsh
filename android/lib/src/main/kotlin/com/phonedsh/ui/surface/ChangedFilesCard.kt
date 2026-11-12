// The "已编辑 N 个文件" card under a closed turn's answer.
// SPDX-License-Identifier: MIT
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeChangedFilesCard.swift`.
//
// What iOS draws, and what this card therefore draws:
//
//   * header 60 pt tall on the selector fill (`:44-46`), a 40 x 40 rounded glyph
//     box (`:19-29`), the title "已编辑 N 个文件" or "已编辑 <file>" when the turn
//     touched exactly one file (`:31-32`), and `+N -M` in the success/danger inks
//     (`:36-41`);
//   * a hairline, then the first four files, one row each: path in the tertiary
//     ink at 12 pt, `+n -m` in monospaced 11 pt (`:51-74`);
//   * a "全部 N 个文件" toggle when the turn touched more than four (`:75-90`),
//     which rotates to 收起 once open;
//   * the card is `colors.input` with a 0.5 pt border and a 12 pt radius (`:93-97`).
//
// The counts are *not* invented here: they come from the same line diff the iOS
// projector runs (`NativeTranscriptProjector.swift:240-254`), ported in
// [lineDelta] and covered by a parity test.
package com.phonedsh.ui.surface

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.PdshChevron
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

/** Test tag of the changed-files card. */
internal const val CHANGED_FILES_TAG: String = "pdsh.surface.changedFiles"

/** Test tag of one file row inside the card. */
internal const val CHANGED_FILES_ROW_TAG: String = "pdsh.surface.changedFiles.row"

/** Test tag of the "全部 N 个文件" toggle. */
internal const val CHANGED_FILES_TOGGLE_TAG: String = "pdsh.surface.changedFiles.toggle"

/** Test tag of the toggle's rotating chevron. */
internal const val CHANGED_FILES_CHEVRON_TAG: String = "pdsh.surface.changedFiles.toggle.chevron"

/**
 * One file a closed turn changed (iOS `NativeChangedFile`).
 *
 * @param path the workspace-relative path, used to open the file.
 * @param display the line the card prints (iOS falls back to the path).
 * @param added lines the turn added (`+N`).
 * @param deleted lines the turn removed (`-N`).
 */
public data class ChatFileChange(
    public val path: String,
    public val display: String,
    public val added: Int,
    public val deleted: Int,
) {
    /** The file name shown when the turn touched exactly one file. */
    public val fileName: String get() = display.substringAfterLast('/')
}

/**
 * The card that lists the files a closed turn edited.
 *
 * @param changes the turn's files in projection order; empty hides the card.
 * @param modifier the row's placement.
 * @param onOpenFile the host's router for a path; the card never navigates.
 */
@Composable
public fun ChangedFilesCard(
    changes: List<ChatFileChange>,
    modifier: Modifier = Modifier,
    onOpenFile: (String) -> Unit = {},
) {
    val files = mergeChangedFiles(changes)
    if (files.isEmpty()) return
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val shape = RoundedCornerShape(tokens.radius.card)
    // iOS keeps the fold in local state (`@State private var expanded`), so it is
    // screen state, not a projection: `remember` is the same lifetime.
    var expanded by remember { mutableStateOf(false) }
    val single = files.singleOrNull()

    Column(
        modifier = modifier
            .fillMaxWidth()
            .testTag(CHANGED_FILES_TAG)
            .clip(shape)
            .background(tokens.colors.input)
            .border(width = tokens.stroke.hairline, color = tokens.colors.border, shape = shape),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                // iOS header fill = `NativeChatTheme.selector` (#F5F6F7); the
                // approval-card token already carries that value on this side.
                .background(tokens.colors.approvalCard)
                .clickable(role = Role.Button) { onOpenFile(files.first().path) }
                // iOS fixes the header at 60pt with 10pt padding and a 40pt glyph box.
                .height(ChatMetrics.CHANGED_FILES_HEADER_HEIGHT_PT.dp)
                .padding(ChatMetrics.CHANGED_FILES_HEADER_INSET_PT.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_HEADER_GAP_PT.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(ChatMetrics.CHANGED_FILES_HEADER_GLYPH_BOX_PT.dp)
                    .clip(RoundedCornerShape(ChatMetrics.CHANGED_FILES_HEADER_GLYPH_RADIUS_PT.dp))
                    .background(tokens.colors.input)
                    .border(
                        width = tokens.stroke.hairline,
                        color = tokens.colors.border,
                        shape = RoundedCornerShape(ChatMetrics.CHANGED_FILES_HEADER_GLYPH_RADIUS_PT.dp),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                PdshIconView(
                    icon = PdshIcon.DOCUMENT,
                    size = ChatMetrics.CHANGED_FILES_HEADER_GLYPH_SIZE_PT.dp,
                    tint = tokens.colors.tertiary,
                    contentDescription = null,
                )
            }
            Column(verticalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_TITLE_STACK_GAP_PT.dp)) {
                BasicText(
                    text = single?.let {
                        UiStrings.CHANGED_FILES_SINGLE.format(it.path.substringAfterLast('/'))
                    } ?: UiStrings.CHANGED_FILES_TITLE.format(files.size),
                    style = type.secondary.copy(
                        color = tokens.colors.primary,
                        fontWeight = FontWeight.Medium,
                        lineHeight = TextUnit.Unspecified,
                    ),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_DIFF_COUNT_GAP_PT.dp)) {
                    BasicText(
                        text = "+${files.sumOf { it.added }}",
                        style = type.code.copy(
                            color = tokens.colors.success,
                            fontSize = ChatMetrics.CHANGED_FILES_HEADER_COUNT_SIZE_PT.sp,
                        ),
                    )
                    BasicText(
                        text = "-${files.sumOf { it.deleted }}",
                        style = type.code.copy(
                            color = tokens.colors.danger,
                            fontSize = ChatMetrics.CHANGED_FILES_HEADER_COUNT_SIZE_PT.sp,
                        ),
                    )
                }
            }
        }

        if (single == null) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(tokens.stroke.hairline)
                    .background(tokens.colors.border),
            )
            // The first four rows are always visible (`NativeChangedFilesCard.swift:14`).
            files.take(VISIBLE_FILES).forEach { file ->
                ChangedFileRow(file = file, onOpenFile = onOpenFile)
            }
            if (files.size > VISIBLE_FILES) {
                // `interaction.md` §7 rule 1: 變更檔 folds with motion.disclosure.
                // The toggle is the fixed header; the remaining rows are the one
                // animated body, so a tap never moves the tapped control.
                val toggle = if (expanded) {
                    UiStrings.CHANGED_FILES_COLLAPSE
                } else {
                    UiStrings.CHANGED_FILES_ALL.format(files.size)
                }
                PdshDisclosure(
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    tag = CHANGED_FILES_TOGGLE_TAG,
                    anchorKey = files.size,
                    header = {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(CHANGED_FILES_TOGGLE_TAG)
                                .semantics(mergeDescendants = true) {
                                    contentDescription = toggle
                                    stateDescription = if (expanded) {
                                        UiStrings.EXPANDED
                                    } else {
                                        UiStrings.COLLAPSED
                                    }
                                }
                                // iOS toggle: 14 h / 10 v inset inside a 44 pt floor (`:84-86`).
                                .defaultMinSize(minHeight = ChatMetrics.CHANGED_FILES_ROW_MIN_HEIGHT_PT.dp)
                                .padding(horizontal = ChatMetrics.CHANGED_FILES_TOGGLE_INSET_H_PT.dp)
                                .padding(vertical = ChatMetrics.CHANGED_FILES_TOGGLE_INSET_V_PT.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_TOGGLE_GAP_PT.dp),
                        ) {
                            BasicText(
                                text = toggle,
                                style = type.caption.copy(color = tokens.colors.tertiary),
                            )
                            PdshChevron(
                                expanded = expanded,
                                size = ChatMetrics.CHANGED_FILES_TOGGLE_CHEVRON_SIZE_PT.dp,
                                tint = tokens.colors.tertiary,
                                tag = CHANGED_FILES_CHEVRON_TAG,
                            )
                        }
                    },
                    body = {
                        files.drop(VISIBLE_FILES).forEach { file ->
                            ChangedFileRow(file = file, onOpenFile = onOpenFile)
                        }
                    },
                )
            }
        }
    }
}

/** One file row (iOS `NativeChangedFilesCard` `:67`–`:78`). */
@Composable
private fun ChangedFileRow(file: ChatFileChange, onOpenFile: (String) -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button) { onOpenFile(file.path) }
            .testTag(CHANGED_FILES_ROW_TAG)
            // iOS row: 14 h inset and a 44 pt floor *including* it
            // (`:68-70`), so the floor is outside the padding.
            .defaultMinSize(minHeight = ChatMetrics.CHANGED_FILES_ROW_MIN_HEIGHT_PT.dp)
            .padding(horizontal = ChatMetrics.CHANGED_FILES_ROW_INSET_H_PT.dp)
            .padding(vertical = ChatMetrics.CHANGED_FILES_ROW_INSET_V_PT.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_ROW_GAP_PT.dp),
    ) {
        BasicText(
            text = file.display,
            style = type.caption.copy(color = tokens.colors.tertiary),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(ChatMetrics.CHANGED_FILES_DIFF_COUNT_GAP_PT.dp)) {
            BasicText(
                text = "+${file.added}",
                style = type.code.copy(
                    color = tokens.colors.success,
                    fontSize = type.codeAction.fontSize,
                ),
            )
            BasicText(
                text = "-${file.deleted}",
                style = type.code.copy(
                    color = tokens.colors.danger,
                    fontSize = type.codeAction.fontSize,
                ),
            )
        }
    }
}

/**
 * Keep one row per workspace path, preserving first-touch order and the latest
 * successful write's display and line counts, matching the iOS turn projector.
 */
internal fun mergeChangedFiles(changes: List<ChatFileChange>): List<ChatFileChange> {
    val byPath = LinkedHashMap<String, ChatFileChange>()
    changes.forEach { change -> byPath[change.path] = change }
    return byPath.values.toList()
}

/**
 * The iOS line diff (`NativeTranscriptProjector.swift:240-254`): the longest
 * common subsequence of *lines*, then `added = new - common`, `deleted = old - common`.
 *
 * Ported literally, including its treatment of a missing old text as one empty
 * line (a `write` therefore reports `-1` for the line it replaced), because the
 * card's numbers are only right when they equal the iOS projection's.
 *
 * @param old the tool's `old_string` / `old_str`, or `null` for a create.
 * @param new the tool's `new_string` / `content` / `file_text`.
 * @return added then deleted line counts.
 */
public fun lineDelta(old: String?, new: String): Pair<Int, Int> {
    val oldLines = newlineComponents(old ?: "")
    val newLines = newlineComponents(new)
    if (oldLines.size.toLong() * newLines.size.toLong() > MAX_DIFF_CELLS) {
        // The iOS algorithm is O(n*m) in time and memory; so is this port. A file
        // too large to diff is reported wholesale instead of OOMing the transcript.
        return newLines.size to oldLines.size
    }
    val table = Array(oldLines.size + 1) { IntArray(newLines.size + 1) }
    for (i in oldLines.indices.reversed()) {
        for (j in newLines.indices.reversed()) {
            table[i][j] = if (oldLines[i] == newLines[j]) {
                table[i + 1][j + 1] + 1
            } else {
                maxOf(table[i + 1][j], table[i][j + 1])
            }
        }
    }
    val common = table[0][0]
    return (newLines.size - common) to (oldLines.size - common)
}

/**
 * Foundation's `components(separatedBy: .newlines)`: *every* newline character is
 * its own separator, so `\r\n` yields an empty component (the iOS algorithm sees
 * the same list) and an empty string yields one empty line.
 */
private fun newlineComponents(text: String): List<String> {
    val out = mutableListOf<String>()
    val current = StringBuilder()
    text.forEach { char ->
        if (char in NEWLINES) {
            out.add(current.toString())
            current.clear()
        } else {
            current.append(char)
        }
    }
    out.add(current.toString())
    return out
}

/** The four rows the iOS card shows before its "全部" toggle (`:12`). */
private const val VISIBLE_FILES: Int = 4

/** Largest old x new line pair matrix this port will allocate. */
private const val MAX_DIFF_CELLS: Long = 4_000_000

/** Foundation `CharacterSet.newlines`. */
private val NEWLINES: Set<Char> = setOf('\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029')
