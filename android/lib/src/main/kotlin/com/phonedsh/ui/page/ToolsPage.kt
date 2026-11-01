// Commands: the read-only accelerator list and the one run form, mirrored.
// SPDX-License-Identifier: MIT
//
// Mirror source: `examples/probe-app/PhoneDSHProbe/PDSHShellPage.swift` (read line
// by line; every section, row, control and string below names the lines it
// copies). The baseline is one `List` with three parts, in this order:
//   1. the device card 这台手机 (`:23`–`:32`): 状态 / 网络 / 工作区 and the
//      read-only footnote;
//   2. either the 还没接上命令 empty body (`:33`–`:37`) or the run form
//      运行命令 (`:39`–`:76`), the 输出 section (`:77`–`:83`) and the 限制 section
//      (`:84`–`:89`).
//
// The baseline never accepts a shell command string: `argv[0]` must come from the
// linked caps (`:6`–`:7`), which is why the picker's choices are exactly the
// host's accelerator names and why 运行 cannot start a command the host did not
// list. `phone` and `ctx` need the app itself and are called out (`:43`–`:46`)
// and disabled (`:69`).
//
// ScreenState: `ToolsScreenState.from(snapshot, local)` is a pure function of the
// host's read-only snapshot and the local form script (selected command, working
// directory, arguments). §3.1 rule 3 makes the caps snapshot the UiState-side
// input on a page with no harness event anchor, so the section/row sequence is
// replayable and asserted on the JVM. The page never reads a clock, a process or
// the network: output and the error line are host data.
//
// Geometry: the page margin and the row floor are page-level tokens
// (`geometry.pageOuterMarginH`, `geometry.pageRowMinHeight`); nothing here
// reuses a signature-surface geometry, so no `unverified geometry` marker remains.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.generated.UiTokenNames

// ---------------------------------------------------------------------------
// Facts
// ---------------------------------------------------------------------------

/**
 * `provider.limits` (`PDSHShellPage.swift:85`–`:88`).
 *
 * Every bound is nullable: a host that did not report one gets 未知 on its row,
 * never a 0 or a default.
 */
@Immutable
public data class ShellLimits(
    public val timeoutMilliseconds: Long? = null,
    public val maxOutputBytes: Long? = null,
    public val maxFiles: Int? = null,
    public val maxFileBytes: Long? = null,
)

/**
 * One exec run, as the host reports it (`:17`, `:78`–`:82`, `:109`–`:113`).
 *
 * @param output the stdout/stderr the host streamed, plus its own end marker.
 * @param error the failure that stopped the run; `null` when it did not fail.
 * @param runningExecId the exec id while a run is in flight (`runningID`).
 */
@Immutable
public data class ShellRun(
    public val output: String = "",
    public val error: String? = null,
    public val runningExecId: String? = null,
)

/**
 * The host's accelerator snapshot: the linked caps and their limits.
 *
 * @param commands `provider.acceleratorNames`; `null` when no provider is linked,
 *   which is the baseline's empty array (`:19`) and its 未链接或未配置 status.
 * @param environment `provider.capabilities.environment`; `null` unmeasured.
 * @param mounts `provider.helloMounts.count`; `null` unmeasured, `0` is 未设置.
 * @param limits the provider's bounds; `null` unmeasured.
 * @param run the current (or last) run.
 */
@Immutable
public data class ShellSnapshot(
    public val commands: List<String>? = null,
    public val environment: String? = null,
    public val mounts: Int? = null,
    public val limits: ShellLimits? = null,
    public val run: ShellRun = ShellRun(),
)

/** One 限制 row (`:85`–`:88`). */
@Immutable
public data class ShellLimitView(
    public val label: String,
    /** The formatted bound, or 未知 when the host did not report it. */
    public val value: String,
)

// ---------------------------------------------------------------------------
// ScreenState
// ---------------------------------------------------------------------------

/**
 * The tools screen state.
 *
 * @param commands the picker's choices, in the host's order (`:19`).
 * @param selectedCommand the current choice (`command`); empty when there is none.
 * @param needsApp `:43`: the selected command needs the app and cannot run.
 * @param canRun `:69`: 运行 is enabled.
 * @param running `:70`: a run is in flight, so 取消 is offered.
 * @param workingDirectory the 工作目录 field's text (`/dsh/workspace` by default, `:14`).
 * @param arguments the 参数 field's text, one argument per line (`:49`–`:66`).
 * @param output `:79`: the output body, or the empty sentence.
 * @param error `:78`: the run's failure line, above the output.
 * @param limits the 限制 rows (`:85`–`:88`); empty only when the run form is hidden.
 */
@Immutable
public data class ToolsScreenState(
    public val commands: List<String>,
    public val selectedCommand: String,
    public val needsApp: Boolean,
    public val canRun: Boolean,
    public val running: Boolean,
    public val statusLabel: String,
    public val workspaceLabel: String,
    public val workingDirectory: String,
    public val arguments: String,
    public val output: String,
    public val error: String?,
    public val limits: List<ShellLimitView>,
) {
    /** True when the host linked no accelerator: the 还没接上命令 body replaces the form. */
    public val isEmpty: Boolean get() = commands.isEmpty()

    public companion object {
        /**
         * Projects (host snapshot, local form script) into the screen state.
         *
         * Pure: no clock, no process, no I/O. `selectedCommand` falls back to the
         * first command exactly like the baseline's `onAppear` (`:94`), so a fresh
         * page already has a valid choice.
         */
        public fun from(
            snapshot: ShellSnapshot,
            local: ShellLocalState = ShellLocalState(),
        ): ToolsScreenState {
            val commands = snapshot.commands.orEmpty()
            // `:94`: `if command.isEmpty { command = commands.first ?? "" }`.
            val selected = local.command.ifEmpty { commands.firstOrNull().orEmpty() }
            val needsApp = selected in APP_ONLY_COMMANDS
            val running = snapshot.run.runningExecId != null
            return ToolsScreenState(
                commands = commands,
                selectedCommand = selected,
                needsApp = needsApp,
                // `:69`: disabled while running, with no command, or for phone/ctx.
                canRun = !running && selected.isNotEmpty() && !needsApp,
                running = running,
                // `:24`: the caps' environment, or 未链接或未配置 without commands.
                statusLabel = if (commands.isEmpty()) {
                    UiStrings.SHELL_STATUS_UNLINKED
                } else {
                    snapshot.environment ?: UiStrings.UNKNOWN
                },
                // `:27`–`:29`: the count only; an English mount name never reaches the
                // screen. 未设置 is a measured zero, 未知 is an unreported count.
                workspaceLabel = when (val mounts = snapshot.mounts) {
                    null -> UiStrings.UNKNOWN
                    0 -> UiStrings.SHELL_WORKSPACE_UNSET
                    else -> UiStrings.SHELL_WORKSPACE_FOLDERS.format(mounts)
                },
                workingDirectory = local.workingDirectory,
                arguments = local.arguments,
                output = snapshot.run.output,
                error = snapshot.run.error,
                limits = if (commands.isEmpty()) emptyList() else limitRows(snapshot.limits),
            )
        }

        private fun limitRows(limits: ShellLimits?): List<ShellLimitView> = listOf(
            // `:85`: `timeoutMilliseconds / 1000` seconds.
            ShellLimitView(
                label = UiStrings.SHELL_LIMIT_TIMEOUT,
                value = limits?.timeoutMilliseconds?.let {
                    UiStrings.SHELL_LIMIT_TIMEOUT_VALUE.format(it / MILLIS_PER_SECOND)
                } ?: UiStrings.UNKNOWN,
            ),
            ShellLimitView(
                label = UiStrings.SHELL_LIMIT_OUTPUT,
                // A user-visible size mirrors the baseline's `.file` style
                // (`formatFileSize`), not the binary budget formatter.
                value = limits?.maxOutputBytes?.let { formatFileSize(it) } ?: UiStrings.UNKNOWN,
            ),
            ShellLimitView(
                label = UiStrings.SHELL_LIMIT_FILES,
                value = limits?.maxFiles?.toString() ?: UiStrings.UNKNOWN,
            ),
            ShellLimitView(
                label = UiStrings.SHELL_LIMIT_FILE,
                value = limits?.maxFileBytes?.let { formatFileSize(it) } ?: UiStrings.UNKNOWN,
            ),
        )
    }
}

/** The local form script: what the user typed, never what the host ran. */
@Immutable
public data class ShellLocalState(
    public val command: String = "",
    public val workingDirectory: String = DEFAULT_WORKING_DIRECTORY,
    public val arguments: String = "",
)

/** The local UI events of the run form. */
public sealed interface ShellUiEvent {
    /** The picker's choice changed (`:40`–`:42`). */
    public data class SelectCommand(public val name: String) : ShellUiEvent

    /** The 工作目录 field changed (`:47`). */
    public data class SetWorkingDirectory(public val value: String) : ShellUiEvent

    /** The 参数 field changed (`:53`). */
    public data class SetArguments(public val value: String) : ShellUiEvent
}

/**
 * Applies one local event; pure, so a test drives it like a reducer.
 *
 * The run itself is not local state: 运行 asks the host to start an exec and the
 * host's snapshot carries the output back (`:97`–`:119`).
 */
public fun ShellLocalState.apply(event: ShellUiEvent): ShellLocalState = when (event) {
    is ShellUiEvent.SelectCommand -> copy(command = event.name)
    is ShellUiEvent.SetWorkingDirectory -> copy(workingDirectory = event.value)
    is ShellUiEvent.SetArguments -> copy(arguments = event.value)
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

/**
 * The tools screen (`PDSHShellPage`).
 *
 * @param state the pure screen state ([ToolsScreenState.from]).
 * @param onSelectCommand the picker's choice changed (`:40`).
 * @param onWorkingDirectoryChange the 工作目录 field changed (`:47`).
 * @param onArgumentsChange the 参数 field changed (`:53`).
 * @param onRun 运行 was tapped (`:68`).
 * @param onCancel 取消 was tapped while a run is in flight (`:71`).
 * @param onBack leave the page.
 */
@Composable
public fun ToolsPage(
    state: ToolsScreenState,
    onSelectCommand: (String) -> Unit,
    onWorkingDirectoryChange: (String) -> Unit,
    onArgumentsChange: (String) -> Unit,
    onRun: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    PageFrame(
        title = UiStrings.TOOLS,
        onBack = onBack,
        rootTag = UiPageTags.SHELL_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .testTag(UiPageTags.SHELL_LIST),
        ) {
            item(key = "device.header") {
                SessionSectionLabel(
                    text = UiStrings.SHELL_DEVICE_TITLE,
                    modifier = Modifier.testTag(UiPageTags.SHELL_SECTION_DEVICE),
                )
            }
            item(key = "device.status") {
                InfoRow(
                    title = UiStrings.SHELL_STATUS,
                    value = state.statusLabel,
                    modifier = Modifier.testTag(UiPageTags.SHELL_STATUS),
                )
            }
            item(key = "device.network") {
                // `:25`: the baseline hard-codes 不可用; this page says the same.
                InfoRow(
                    title = UiStrings.SHELL_NETWORK,
                    value = UiStrings.SHELL_NETWORK_UNAVAILABLE,
                    modifier = Modifier.testTag(UiPageTags.SHELL_NETWORK),
                )
            }
            item(key = "device.workspace") {
                InfoRow(
                    title = UiStrings.SHELL_WORKSPACE,
                    value = state.workspaceLabel,
                    modifier = Modifier.testTag(UiPageTags.SHELL_WORKSPACE),
                )
            }
            item(key = "device.footnote") {
                Footnote(text = UiStrings.SHELL_READ_ONLY, tag = UiPageTags.SHELL_READ_ONLY)
            }

            if (state.isEmpty) {
                // `:33`–`:37`: the baseline's ContentUnavailableView, with no section
                // title above it.
                item(key = "empty") {
                    UnavailableBody()
                }
            } else {
                item(key = "run.header") {
                    SessionSectionLabel(
                        text = UiStrings.SHELL_RUN_TITLE,
                        modifier = Modifier.testTag(UiPageTags.SHELL_SECTION_RUN),
                    )
                }
                // `:40`–`:42`: the Picker's label and its choices. The baseline
                // renders a menu; a list of choices carries the same set and the
                // same selection, and keeps every row addressable.
                item(key = "run.picker") {
                    PickerRow(selected = state.selectedCommand)
                }
                state.commands.forEach { command ->
                    item(key = "command.$command") {
                        CommandRow(
                            name = command,
                            selected = command == state.selectedCommand,
                            onSelect = { onSelectCommand(command) },
                        )
                    }
                }
                if (state.needsApp) {
                    // `:43`–`:46`: phone/ctx need the app itself.
                    item(key = "run.needsapp") {
                        Footnote(text = UiStrings.SHELL_NEEDS_APP, tag = UiPageTags.SHELL_NEEDS_APP)
                    }
                }
                item(key = "run.workdir") {
                    LabeledField(
                        label = UiStrings.SHELL_WORKING_DIR,
                        value = state.workingDirectory,
                        onValueChange = onWorkingDirectoryChange,
                        tag = UiPageTags.SHELL_WORKING_DIR,
                        singleLine = true,
                    )
                }
                item(key = "run.arguments") {
                    LabeledField(
                        label = UiStrings.SHELL_ARGUMENTS,
                        value = state.arguments,
                        onValueChange = onArgumentsChange,
                        tag = UiPageTags.SHELL_ARGUMENTS,
                        singleLine = false,
                        placeholder = UiStrings.SHELL_ARGUMENTS_PLACEHOLDER,
                    )
                }
                item(key = "run.actions") {
                    RunActions(
                        canRun = state.canRun,
                        running = state.running,
                        onRun = onRun,
                        onCancel = onCancel,
                    )
                }

                item(key = "output.header") {
                    SessionSectionLabel(
                        text = UiStrings.SHELL_OUTPUT_TITLE,
                        modifier = Modifier.testTag(UiPageTags.SHELL_SECTION_OUTPUT),
                    )
                }
                if (state.error != null) {
                    // `:78`: the failure line above the output, in red.
                    item(key = "output.error") {
                        ErrorLine(message = state.error)
                    }
                }
                item(key = "output.body") {
                    OutputBody(output = state.output)
                }

                item(key = "limits.header") {
                    SessionSectionLabel(
                        text = UiStrings.SHELL_LIMITS_TITLE,
                        modifier = Modifier.testTag(UiPageTags.SHELL_SECTION_LIMITS),
                    )
                }
                state.limits.forEach { limit ->
                    item(key = "limit.${limit.label}") {
                        InfoRow(
                            title = limit.label,
                            value = limit.value,
                            modifier = Modifier.testTag(UiPageTags.SHELL_LIMIT_PREFIX + limit.label),
                        )
                    }
                }
            }
        }
    }
}

/** The Picker's own label row (`:40`): the choices follow it. */
@Composable
private fun PickerRow(selected: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SHELL_COMMAND)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.SHELL_COMMAND,
            style = type.body.copy(color = tokens.colors.primary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = selected,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
    }
}

/** One choice of the picker (`:41`): the row selects itself. */
@Composable
private fun CommandRow(name: String, selected: Boolean, onSelect: () -> Unit) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SHELL_COMMAND_ROW_PREFIX + name)
            .clickable(role = Role.Button, onClick = onSelect)
            // Page-level geometry: a choice is a page row and uses its floor.
            .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            )
            .semantics(mergeDescendants = true) { contentDescription = name },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = if (selected) SELECTED_GLYPH else UNSELECTED_GLYPH,
            style = type.body.copy(
                color = if (selected) tokens.colors.accent else tokens.colors.tertiary,
            ),
        )
        BasicText(
            text = name,
            style = type.body.copy(
                color = if (selected) tokens.colors.accent else tokens.colors.primary,
            ),
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * One labelled field: the 工作目录 field (`:47`) and the 参数 box (`:49`–`:66`).
 *
 * The baseline's 参数 box has a six-point label gap and a fixed 112 pt height. The
 * `tokens.json` table declares no page-level field height, so the box takes its
 * content height plus the caps' inset instead of inventing 112; its fill and its
 * hairline are the theme's `selector` and `border` (`:63`–`:64`).
 */
@Composable
private fun LabeledField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    tag: String,
    singleLine: Boolean,
    placeholder: String? = null,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.caption.copy(color = tokens.colors.secondary),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = singleLine,
            textStyle = type.body.copy(color = tokens.colors.primary),
            cursorBrush = SolidColor(tokens.colors.accent),
            modifier = Modifier
                .fillMaxWidth()
                .testTag(tag)
                .semantics { contentDescription = label }
                .clipField(tokens)
                .defaultMinSize(minHeight = tokens.geometry.pageRowMinHeight)
                .padding(tokens.spacing.cardInset),
            decorationBox = { inner ->
                if (value.isEmpty() && placeholder != null) {
                    BasicText(
                        text = placeholder,
                        style = type.code.copy(color = tokens.colors.tertiary),
                    )
                }
                inner()
            },
        )
    }
}

/** The field's fill and hairline: the baseline's quaternary box (`:63`–`:64`). */
@Composable
private fun Modifier.clipField(tokens: com.phonedsh.ui.theme.UiTokens): Modifier {
    val shape = RoundedCornerShape(tokens.radius.codeBlock)
    return this
        .background(tokens.colors.selector, shape)
        .border(tokens.stroke.hairline, tokens.colors.border, shape)
}

/** The 运行 / 取消 row (`:67`–`:75`). */
@Composable
private fun RunActions(
    canRun: Boolean,
    running: Boolean,
    onRun: () -> Unit,
    onCancel: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        SessionTextAction(
            label = UiStrings.SHELL_RUN,
            onClick = onRun,
            tone = SessionActionTone.ACCENT,
            enabled = canRun,
            modifier = Modifier.testTag(UiPageTags.SHELL_RUN),
        )
        if (running) {
            // `:70`–`:74`: 取消 exists only while a run is in flight, and it is
            // destructive.
            SessionTextAction(
                label = UiStrings.SHELL_CANCEL,
                onClick = onCancel,
                tone = SessionActionTone.DANGER,
                modifier = Modifier.testTag(UiPageTags.SHELL_CANCEL),
            )
        }
    }
}

/** The output body (`:79`): the run's text, or the empty sentence. */
@Composable
private fun OutputBody(output: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = output.ifEmpty { UiStrings.SHELL_OUTPUT_EMPTY },
        style = type.code.copy(color = tokens.colors.primary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SHELL_OUTPUT)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The run's failure line (`:78`). */
@Composable
private fun ErrorLine(message: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = message,
        style = type.secondary.copy(color = tokens.colors.danger),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SHELL_ERROR)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** A footnote sentence under a section's rows (`:30`, `:44`). */
@Composable
private fun Footnote(text: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    BasicText(
        text = text,
        style = type.caption.copy(color = tokens.colors.secondary),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.badgeInsetV,
            ),
    )
}

/** The 还没接上命令 body (`:35`–`:36`): a title and its description. */
@Composable
private fun UnavailableBody() {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.SHELL_EMPTY)
            .padding(
                horizontal = tokens.geometry.pageOuterMarginH,
                vertical = tokens.spacing.cardInset,
            )
            .semantics(mergeDescendants = true) {},
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = UiStrings.SHELL_EMPTY,
            style = type.headline.copy(color = tokens.colors.primary),
        )
        BasicText(
            text = UiStrings.SHELL_EMPTY_HINT,
            style = type.secondary.copy(color = tokens.colors.secondary),
        )
    }
}

/** The glyph of the picker's selected choice. */
private const val SELECTED_GLYPH: String = "✓"

/** The glyph of a choice that is not selected. */
private const val UNSELECTED_GLYPH: String = "○"

/** `PDSHShellPage.swift:43`: the two commands that need the app itself. */
private val APP_ONLY_COMMANDS: Set<String> = setOf("phone", "ctx")

/** `PDSHShellPage.swift:14`: the initial working directory. */
private const val DEFAULT_WORKING_DIRECTORY: String = "/dsh/workspace"

private const val MILLIS_PER_SECOND: Long = 1000

/**
 * The token inventory of this page; `PageTokenReferenceTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object ToolsPageTokens {
    val refs: List<String> = listOf(
        UiTokenNames.COLORS_PRIMARY,
        UiTokenNames.COLORS_SECONDARY,
        UiTokenNames.COLORS_TERTIARY,
        UiTokenNames.COLORS_ACCENT,
        UiTokenNames.COLORS_DANGER,
        UiTokenNames.COLORS_SELECTOR,
        UiTokenNames.COLORS_BORDER,
        UiTokenNames.TYPOGRAPHY_BODY,
        UiTokenNames.TYPOGRAPHY_SECONDARY,
        UiTokenNames.TYPOGRAPHY_CAPTION,
        UiTokenNames.TYPOGRAPHY_CODE,
        UiTokenNames.TYPOGRAPHY_HEADLINE,
        UiTokenNames.SPACING_ICON_TEXT,
        UiTokenNames.SPACING_BADGE_INSET_V,
        UiTokenNames.SPACING_CARD_INSET,
        UiTokenNames.STROKE_HAIRLINE,
        UiTokenNames.RADIUS_CODE_BLOCK,
        UiTokenNames.GEOMETRY_PAGE_OUTER_MARGIN_H,
        UiTokenNames.GEOMETRY_PAGE_ROW_MIN_HEIGHT,
    )
}
