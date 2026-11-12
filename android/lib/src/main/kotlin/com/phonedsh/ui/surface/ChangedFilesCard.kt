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
//   * when the turn touched more than four, one animated body with rows 5..N
//     *above* the toggle (`:12-14`, `:54-90`);
//   * a "全部 N 个文件" toggle whose chevron.down rotates 0°→180° in the same
//     motion.disclosure animation, and whose label becomes 收起 once open;
//   * the card is `colors.input` with a 0.5 pt border and a 12 pt radius (`:93-97`).
//
// The counts are *not* invented here: they come from the same line diff the iOS
// projector runs (`NativeTranscriptProjector.swift:240-254`), ported in
// [lineDelta] and covered by a parity test.
package com.phonedsh.ui.surface

import android.provider.Settings
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
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
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.sp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.DisclosureSpec
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiMotion

/** Test tag of the changed-files card. */
internal const val CHANGED_FILES_TAG: String = "pdsh.surface.changedFiles"

/** Test tag of one file row inside the card. */
internal const val CHANGED_FILES_ROW_TAG: String = "pdsh.surface.changedFiles.row"

/** Test tag of the animated body holding rows 5..N above the toggle. */
internal const val CHANGED_FILES_BODY_TAG: String = "pdsh.surface.changedFiles.body"

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
    ChangedFilesCardContent(
        changes = changes,
        modifier = modifier,
        onOpenFile = onOpenFile,
        onChevronRotationChanged = null,
    )
}

/**
 * [ChangedFilesCard] with a JVM-observable chevron rotation.
 *
 * The rotation is only a draw transform, so Compose semantics cannot read it.
 * The production overload passes `null`; this is the same observer seam
 * `PdshChevron` offers to hosts.
 */
@Composable
internal fun ChangedFilesCardWithChevronObserver(
    changes: List<ChatFileChange>,
    modifier: Modifier = Modifier,
    onOpenFile: (String) -> Unit = {},
    onChevronRotationChanged: (Float) -> Unit,
) {
    ChangedFilesCardContent(
        changes = changes,
        modifier = modifier,
        onOpenFile = onOpenFile,
        onChevronRotationChanged = onChevronRotationChanged,
    )
}

@Composable
private fun ChangedFilesCardContent(
    changes: List<ChatFileChange>,
    modifier: Modifier,
    onOpenFile: (String) -> Unit,
    onChevronRotationChanged: ((Float) -> Unit)?,
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
    val reducedMotion = rememberPlatformReducedMotion(expanded)
    // `interaction.md` §7 rule 1: the changed-file body folds with motion.disclosure.
    val bodySpec = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion)
    val sizeSpec = disclosureAnimationSpec<IntSize>(bodySpec, tokens.motion)
    val fadeSpec = disclosureAnimationSpec<Float>(bodySpec, tokens.motion)

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
                val toggle = if (expanded) {
                    UiStrings.CHANGED_FILES_COLLAPSE
                } else {
                    UiStrings.CHANGED_FILES_ALL.format(files.size)
                }
                // iOS renders rows 5..N *above* the toggle (`NativeChangedFilesCard.swift:54-90`):
                // one animated body that grows between row 4 and the control, so
                // expanding never moves anything above the toggle except by growing
                // (§7 rule 6).
                val body: @Composable () -> Unit = {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(CHANGED_FILES_BODY_TAG),
                    ) {
                        files.drop(VISIBLE_FILES).forEach { file ->
                            ChangedFileRow(file = file, onOpenFile = onOpenFile)
                        }
                    }
                }
                if (bodySpec.snap) {
                    // Rule 5: the platform disabled animations; compose the end
                    // state directly instead of running a zero-duration transition.
                    if (expanded) body()
                } else {
                    AnimatedVisibility(
                        visible = expanded,
                        enter = expandVertically(
                            animationSpec = sizeSpec,
                            expandFrom = Alignment.Top,
                        ) + fadeIn(animationSpec = fadeSpec),
                        exit = shrinkVertically(
                            animationSpec = sizeSpec,
                            shrinkTowards = Alignment.Top,
                        ) + fadeOut(animationSpec = fadeSpec),
                    ) {
                        body()
                    }
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(CHANGED_FILES_TOGGLE_TAG)
                        .clickable(role = Role.Button) { expanded = !expanded }
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
                    ChangedFilesChevron(
                        expanded = expanded,
                        spec = bodySpec,
                        tint = tokens.colors.tertiary,
                        onRotationChanged = onChevronRotationChanged,
                    )
                }
            }
        }
    }
}

/**
 * iOS rotates `chevron.down` 0°→180° inside the same `withAnimation` as the
 * body (`NativeChangedFilesCard.swift:77-81`), so it reads the BODY disclosure
 * spec, not `motion.chevron` (that one is the subagent 0°→90° mark).
 */
@Composable
private fun ChangedFilesChevron(
    expanded: Boolean,
    spec: DisclosureSpec,
    tint: Color,
    onRotationChanged: ((Float) -> Unit)?,
) {
    val target = if (expanded) 180f else 0f
    val animated by animateFloatAsState(
        targetValue = target,
        animationSpec = disclosureAnimationSpec<Float>(spec, LocalUiTokens.current.motion),
        label = "pdsh-changed-files-chevron",
    )
    val rotation = if (spec.snap) target else animated
    if (onRotationChanged != null) {
        SideEffect { onRotationChanged(rotation) }
    }
    PdshIconView(
        icon = PdshIcon.CHEVRON_DOWN,
        size = ChatMetrics.CHANGED_FILES_TOGGLE_CHEVRON_SIZE_PT.dp,
        tint = tint,
        contentDescription = null,
        modifier = Modifier
            .testTag(CHANGED_FILES_CHEVRON_TAG)
            .rotate(rotation),
    )
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

/** Rule 5: the platform animator duration scale is the only reduced-motion input. */
@Composable
private fun rememberPlatformReducedMotion(key: Any?): Boolean {
    val context = LocalContext.current
    return remember(key, context) {
        Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }
}

/** One contract motion for every property, or the contract's reduced-motion snap. */
private fun <T> disclosureAnimationSpec(spec: DisclosureSpec, motion: UiMotion): FiniteAnimationSpec<T> =
    if (spec.snap) {
        snap()
    } else {
        tween(durationMillis = spec.durationMs, easing = motion.easing(spec.curve))
    }

/** The four rows the iOS card shows before its "全部" toggle (`:12`). */
private const val VISIBLE_FILES: Int = 4

/** Largest old x new line pair matrix this port will allocate. */
private const val MAX_DIFF_CELLS: Long = 4_000_000

/** Foundation `CharacterSet.newlines`. */
private val NEWLINES: Set<Char> = setOf('\n', '\r', '\u000B', '\u000C', '\u0085', '\u2028', '\u2029')
