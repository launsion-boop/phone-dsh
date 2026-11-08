// The settings destination for archived sessions.
// SPDX-License-Identifier: MIT
//
// Authority: the private `ArchivedSessionsPage` in the frozen iOS
// `PhoneDSHProbe/SettingsPage.swift`. The host supplies the archive snapshot and
// typed mutation receipts; this page never invents demo rows or treats a restore
// callback as proof that the host restored anything.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CornerSize
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.text.font.FontWeight
import com.phonedsh.ui.SettingsMetrics
import com.phonedsh.ui.surface.SettingsCardRadius
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import java.time.ZoneId

/** The archive read outcome; unknown and empty are kept distinct. */
public enum class ArchivedSessionsPageStatus { WAITING, READY, EMPTY, UNKNOWN, FAILED }

/** Host snapshot projected for the archived-session settings destination. */
public data class ArchivedSessionsPageState(
    public val status: ArchivedSessionsPageStatus,
    public val rows: List<ArchivedRowView>,
    public val failure: String? = null,
    /** The last host-confirmed restore result, if one was reported. */
    public val mutationReceipt: PageMutationReceipt? = null,
) {
    public companion object {
        /** Pure host-fact projection; callers supply time so row labels replay deterministically. */
        public fun from(
            sessions: List<SessionListing>?,
            nowMs: Long,
            zone: ZoneId,
            waiting: Boolean = false,
            failure: String? = null,
            mutationReceipt: PageMutationReceipt? = null,
        ): ArchivedSessionsPageState {
            val status = when {
                failure != null -> ArchivedSessionsPageStatus.FAILED
                waiting -> ArchivedSessionsPageStatus.WAITING
                sessions == null -> ArchivedSessionsPageStatus.UNKNOWN
                sessions.isEmpty() -> ArchivedSessionsPageStatus.EMPTY
                else -> ArchivedSessionsPageStatus.READY
            }
            val rows = sessions.orEmpty().map { session ->
                ArchivedRowView(
                    id = session.id,
                    title = sessionTitle(session.title, 1),
                    timeLabel = session.updatedAtMs?.let { relativeTime(it, nowMs, zone) },
                )
            }
            return ArchivedSessionsPageState(status, rows, failure, mutationReceipt)
        }
    }
}

/**
 * Archived-session settings page.
 *
 * A restore control is disabled when the host did not provide a restore command.
 * The page only shows a success line after [state] carries a host-confirmed
 * [PageMutationReceipt].
 */
@Composable
public fun ArchivedSessionsPage(
    state: ArchivedSessionsPageState,
    onBack: () -> Unit,
    onRestore: ((ArchivedRowView) -> Unit)? = null,
    onRetry: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SettingsSubPageFrame(
        title = UiStrings.SETTINGS_ROW_ARCHIVED_SESSIONS,
        onBack = onBack,
        backGlyph = ARCHIVE_PAGE_BACK_GLYPH,
        backTag = ARCHIVED_PAGE_BACK_TAG,
        rootTag = UiPageTags.SETTINGS_ARCHIVED_ROOT,
        modifier = modifier,
        showSheetHandle = false,
        grouped = true,
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            state.mutationReceipt?.let { PageMutationReceiptLine(it) }
            if (state.status == ArchivedSessionsPageStatus.FAILED) {
                SessionFailureLine(
                    message = state.failure ?: UiStrings.SESSIONS_ARCHIVED_UNKNOWN,
                    tag = ARCHIVED_PAGE_FAILURE_TAG,
                    // No retry: iOS has none, and no host command re-reads the archive
                    // (GAP-32; page-structure-rules.md rule 3). Re-entering the page re-reads.
                    retryLabel = null,
                    onRetry = null,
                )
            }
            if (state.status == ArchivedSessionsPageStatus.WAITING) {
                BasicText(
                    text = UiStrings.WAITING_ENGINE,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(ARCHIVED_PAGE_WAITING_TAG)
                        .padding(tokens.geometry.pageOuterMarginH),
                )
            } else if (state.status == ArchivedSessionsPageStatus.UNKNOWN) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(ARCHIVED_PAGE_UNKNOWN_TAG)
                        .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText)
                        .semantics {
                            contentDescription = "${UiStrings.SESSIONS_ARCHIVED_UNKNOWN}. ${UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT}"
                        },
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        UiStrings.SESSIONS_ARCHIVED_UNKNOWN,
                        style = type.body.copy(color = tokens.colors.textPrimary),
                    )
                    BasicText(
                        UiStrings.SESSIONS_ARCHIVED_UNKNOWN_HINT,
                        style = type.secondary.copy(color = tokens.colors.textSecondary),
                    )
                }
            } else if (state.status == ArchivedSessionsPageStatus.EMPTY) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.SETTINGS_ARCHIVED_EMPTY)
                        .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.cardInset),
                    verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
                ) {
                    BasicText(
                        UiStrings.SESSIONS_ARCHIVED_EMPTY,
                        style = type.body.copy(color = tokens.colors.textPrimary),
                    )
                    BasicText(
                        UiStrings.ARCHIVED_EMPTY_HINT,
                        style = type.secondary.copy(color = tokens.colors.textSecondary),
                    )
                }
            } else if (state.rows.isNotEmpty()) {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .testTag(ARCHIVED_PAGE_LIST_TAG),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.iconText,
                    ),
                ) {
                    itemsIndexed(state.rows, key = { _, row -> row.id }) { index, row ->
                        ArchivedSessionPageRow(row, onRestore, index == 0, index == state.rows.lastIndex)
                    }
                    item(key = "restore-footer") {
                        BasicText(
                            UiStrings.ARCHIVED_RESTORE_FOOTER,
                            style = type.secondary.copy(color = tokens.colors.textSecondary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag(ARCHIVED_PAGE_FOOTER_TAG)
                                .padding(vertical = tokens.spacing.badgeInsetV),
                        )
                    }
                }
            } else if (state.status == ArchivedSessionsPageStatus.FAILED) {
                // An unsuccessful first read cannot be presented as an empty archive.
                Unit
            }
        }
    }
}

@Composable
private fun ArchivedSessionPageRow(
    row: ArchivedRowView,
    onRestore: ((ArchivedRowView) -> Unit)?,
    first: Boolean,
    last: Boolean,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val flat = CornerSize(0)
    val rounded = CornerSize(SettingsCardRadius)
    val shape = RoundedCornerShape(
        topStart = if (first) rounded else flat, topEnd = if (first) rounded else flat,
        bottomStart = if (last) rounded else flat, bottomEnd = if (last) rounded else flat,
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
            .clip(shape)
            .background(tokens.colors.surface)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.badgeInsetV)
            .testTag(UiPageTags.SETTINGS_ARCHIVED_ROW),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(SettingsMetrics.ARCHIVE_TEXT_GAP_PT.dp)) {
            BasicText(
                row.title,
                style = type.body.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
            )
            row.timeLabel?.let { time ->
                BasicText(
                    time,
                    style = type.secondary.copy(
                        color = tokens.colors.textPlaceholder,
                        lineHeight = TextUnit.Unspecified,
                    ),
                    maxLines = 1,
                    modifier = Modifier.testTag(ARCHIVED_PAGE_METADATA_TAG),
                )
            }
        }
        BasicText(
            UiStrings.SESSIONS_RESTORE,
            style = type.processBody.copy(
                fontWeight = FontWeight.Medium,
                lineHeight = TextUnit.Unspecified,
                color = if (onRestore == null) tokens.colors.textTertiary else tokens.colors.textPrimary,
            ),
            modifier = Modifier
                .testTag(UiPageTags.SETTINGS_ARCHIVED_RESTORE)
                .clickable(enabled = onRestore != null, role = Role.Button) { onRestore?.invoke(row) }
                .semantics { contentDescription = "${UiStrings.SESSIONS_RESTORE} ${row.title}" }
                .padding(horizontal = tokens.spacing.badgeInsetH, vertical = tokens.spacing.badgeInsetV),
        )
    }
}

private const val ARCHIVE_PAGE_BACK_GLYPH: String = "‹"
private const val ARCHIVED_PAGE_BACK_TAG: String = "pdsh.settings.archived.back"
internal const val ARCHIVED_PAGE_FAILURE_TAG: String = "pdsh.settings.archived.failure"
private const val ARCHIVED_PAGE_WAITING_TAG: String = "pdsh.settings.archived.waiting"
internal const val ARCHIVED_PAGE_UNKNOWN_TAG: String = "pdsh.settings.archived.unknown"
private const val ARCHIVED_PAGE_LIST_TAG: String = "pdsh.settings.archived.list"
private const val ARCHIVED_PAGE_FOOTER_TAG: String = "pdsh.settings.archived.footer"
private const val ARCHIVED_PAGE_METADATA_TAG: String = "pdsh.settings.archived.metadata"
