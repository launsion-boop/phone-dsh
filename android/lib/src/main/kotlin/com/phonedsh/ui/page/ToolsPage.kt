// Commands: the reducer and screen state behind `PDSHShellPage`.
// SPDX-License-Identifier: MIT
//
// This file used to also declare `ToolsPage`, the legacy 命令 view wrapper. The
// `pdsh-shell` contract maps its Android side at `PDSHShellPage.kt`, `ToolsRoute`
// renders that page, and `ToolsPage` had no caller but its own JVM test — the
// `_android-only.json` entry said the deletion had to happen composable-first, and
// the L55 lane did exactly that (composable + test + registration, in that order).
// What is left is the one reducer both views always shared, so `PDSHShellPage.kt`
// and `PdshNavHost.ToolsRoute` keep compiling against a single state model.
//
// ScreenState: `ToolsScreenState.from(snapshot, local)` is a pure function of the
// host's read-only snapshot and the local form script (selected command, working
// directory, arguments). §3.1 rule 3 makes the caps snapshot the UiState-side
// input on a page with no harness event anchor, so the section/row sequence is
// replayable and asserted on the JVM. Nothing here reads a clock, a process or
// the network: output and the error line are host data.
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

/** `PDSHShellPage.swift:43`: the two commands that need the app itself. */
private val APP_ONLY_COMMANDS: Set<String> = setOf("phone", "ctx")

/** `PDSHShellPage.swift:14`: the initial working directory. */
private const val DEFAULT_WORKING_DIRECTORY: String = "/dsh/workspace"

private const val MILLIS_PER_SECOND: Long = 1000
