// Bot 信息 › 记忆: the document tree, one document's versions, the physical
// erasure entries and the background-maintenance batch.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/Bot/BotInfoPage.swift:805-1280`
// and `spec/ui/v1/bot/ui-state.md` §4.12. `forget` removes only the live
// version; `eraseDocument`/`erase`/`eraseShared` are physical and carry explicit
// scope copy plus a confirmation. The page never removes a row locally after a
// mutation: the host re-reads the authority.
package com.phonedsh.ui.bot.page.info

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.BasicText
import com.phonedsh.ui.bot.state.BotMemoryScope
import com.phonedsh.ui.disclosure.PdshDisclosure
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.page.SessionFailureLine
import com.phonedsh.ui.page.SessionSectionLabel
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.bot.state.BotInfoIntent
import com.phonedsh.ui.bot.state.BotInfoLoadState
import com.phonedsh.ui.bot.state.BotInfoModelState
import com.phonedsh.ui.bot.state.BotMaintenanceBatchInfo
import com.phonedsh.ui.bot.state.BotMemoryDocumentInfo
import com.phonedsh.ui.bot.state.BotMemoryVersionInfo
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType

@Composable
internal fun BotInfoMemoryPage(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    var selectedPath by remember { mutableStateOf<String?>(null) }
    val documents = state.snapshot?.memories.orEmpty()
    val document = selectedPath?.let { path -> documents.firstOrNull { it.path == path } }

    if (document != null) {
        BotMemoryDocumentPage(
            document = document,
            onBack = { selectedPath = null },
            onForget = { onIntent(BotInfoIntent.Forget(document.path, document.version)) },
            onErase = { onIntent(BotInfoIntent.EraseDocument(document.path)) },
            modifier = modifier,
            now = now,
        )
        return
    }

    PageFrame(
        title = BotInfoCopy.MEMORY_TITLE,
        onBack = onBack,
        rootTag = BOT_MEMORY_ROOT,
        modifier = modifier,
        actions = {
            BasicText(
                text = BotInfoCopy.REFRESH,
                style = LocalUiType.current.secondary.copy(
                    color = tokens.colors.primaryButton,
                ),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = { onIntent(BotInfoIntent.Load) })
                    .semantics { contentDescription = BotInfoCopy.REFRESH }
                    .padding(horizontal = BotInfoMetrics.ENTRY_GAP),
            )
        },
    ) {
        when (val load = state.memoryState) {
            BotInfoLoadState.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    Modifier
                        .size(BotInfoMetrics.ACTION)
                        .testTag(BotInfoTags.MEMORY_LOADING),
                    color = tokens.colors.textSecondary,
                )
            }

            is BotInfoLoadState.Failed -> SessionFailureLine(
                message = BotUiStrings.format("info.memory.readFailed", "error" to load.reason),
                tag = BotInfoTags.MEMORY_FAILED,
                retryLabel = UiStrings.RETRY,
                onRetry = { onIntent(BotInfoIntent.Load) },
            )

            BotInfoLoadState.Loaded -> BotMemoryLoaded(
                state = state,
                onIntent = onIntent,
                onOpenDocument = { selectedPath = it.path },
            )
        }
    }
}

@Composable
private fun BotMemoryLoaded(
    state: BotInfoModelState,
    onIntent: (BotInfoIntent) -> Unit,
    onOpenDocument: (BotMemoryDocumentInfo) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val snapshot = state.snapshot
    val memories = snapshot?.memories.orEmpty()
    val botDocuments = memories.filter { it.scope != BotMemoryScope.USER }
    val sharedDocuments = memories.filter { it.scope == BotMemoryScope.USER }
    var forgetting by remember { mutableStateOf<BotMemoryDocumentInfo?>(null) }
    var confirmEraseBot by remember { mutableStateOf(false) }
    var confirmEraseShared by remember { mutableStateOf(false) }
    var confirmEraseSharedAgain by remember { mutableStateOf(false) }
    var confirmRollback by remember { mutableStateOf(false) }

    LazyColumn(
        Modifier.fillMaxSize().testTag(BotInfoTags.MEMORY_LIST),
        verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
    ) {
        item(key = "maintenance") {
            SessionSectionLabel(BotInfoCopy.MAINTENANCE_TITLE)
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = tokens.geometry.pageOuterMarginH)
                    .padding(vertical = tokens.spacing.iconText),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicText(
                    text = BotInfoCopy.MAINTENANCE_SWITCH,
                    style = type.homeBody.copy(color = tokens.colors.textPrimary),
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = snapshot?.maintenanceEnabled ?: false,
                    onCheckedChange = { onIntent(BotInfoIntent.SetMaintenanceEnabled(it)) },
                    modifier = Modifier.testTag(BotInfoTags.MAINTENANCE_TOGGLE),
                )
            }
            val budget = snapshot?.maintenanceDailyBudget ?: 0L
            if (budget > 0L) {
                val used = snapshot?.maintenanceDailyTokens ?: 0L
                val exhausted = used >= budget
                BasicText(
                    text = if (exhausted) {
                        BotInfoCopy.MAINTENANCE_BUDGET_EXHAUSTED
                    } else {
                        BotInfoCopy.format(
                            BotInfoCopy.MAINTENANCE_BUDGET,
                            "ratio" to BotInfoFormat.percent(used, budget),
                        )
                    },
                    style = type.caption.copy(
                        fontSize = BotInfoMetrics.CAPTION_SIZE,
                        color = if (exhausted) tokens.colors.danger else tokens.colors.textTertiary,
                    ),
                    modifier = Modifier
                        .padding(horizontal = tokens.geometry.pageOuterMarginH)
                        .testTag(BotInfoTags.MAINTENANCE_BUDGET),
                )
            }
        }

        snapshot?.maintenance?.let { batch ->
            item(key = "batch") {
                SessionSectionLabel(BotInfoCopy.MAINTENANCE_BATCH)
                BotMaintenanceBatchCard(
                    batch = batch,
                    onRollback = { confirmRollback = true },
                )
            }
        }

        if (botDocuments.isEmpty() && sharedDocuments.isEmpty()) {
            item(key = "empty") {
                BasicText(
                    text = BotInfoCopy.MEMORY_EMPTY,
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier
                        .padding(horizontal = tokens.geometry.pageOuterMarginH)
                        .testTag(BOT_MEMORY_EMPTY),
                )
            }
        } else {
            item(key = "agent-root") {
                BotMemorySection(
                    title = BotUiStrings.INFO_MEMORY_AGENTROOT,
                    documents = botDocuments,
                    root = "agent",
                    onOpenDocument = onOpenDocument,
                    onForget = { forgetting = it },
                )
            }
            item(key = "user-root") {
                BotMemorySection(
                    title = BotUiStrings.INFO_MEMORY_USERROOT,
                    documents = sharedDocuments,
                    root = "user",
                    onOpenDocument = onOpenDocument,
                    onForget = { forgetting = it },
                )
            }
            item(key = "erasure") {
                BotMemoryErasureSection(
                    hasBotDocuments = botDocuments.isNotEmpty(),
                    hasSharedDocuments = sharedDocuments.isNotEmpty(),
                    onEraseBot = { confirmEraseBot = true },
                    onEraseShared = { confirmEraseShared = true },
                )
            }
        }
    }

    forgetting?.let { document ->
        BotInfoConfirmDialog(
            title = BotInfoCopy.FORGET_TITLE,
            message = BotInfoCopy.FORGET_BODY,
            confirmLabel = BotUiStrings.INFO_MEMORY_FORGET,
            confirmTag = BotInfoTags.MEMORY_FORGET_CONFIRM,
            cancelTag = BotInfoTags.MEMORY_FORGET_CANCEL,
            onDismiss = { forgetting = null },
            onConfirm = {
                forgetting = null
                onIntent(BotInfoIntent.Forget(document.path, document.version))
            },
        )
    }
    if (confirmEraseBot) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.ERASE_BOT_TITLE,
            message = BotInfoCopy.ERASE_BOT_BODY,
            confirmLabel = BotInfoCopy.ERASE_BOT_CONFIRM,
            confirmTag = BotInfoTags.MEMORY_ERASE_CONFIRM,
            cancelTag = BOT_MEMORY_ERASE_CANCEL,
            onDismiss = { confirmEraseBot = false },
            onConfirm = {
                confirmEraseBot = false
                onIntent(BotInfoIntent.Erase)
            },
        )
    }
    if (confirmEraseShared) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.ERASE_SHARED_TITLE,
            message = BotInfoCopy.ERASE_SHARED_BODY,
            confirmLabel = BotInfoCopy.ERASE_SHARED_CONFIRM,
            confirmTag = BotInfoTags.MEMORY_ERASE_SHARED_CONFIRM,
            cancelTag = BOT_MEMORY_ERASE_SHARED_CANCEL,
            onDismiss = { confirmEraseShared = false },
            onConfirm = {
                confirmEraseShared = false
                confirmEraseSharedAgain = true
            },
        )
    }
    if (confirmEraseSharedAgain) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.ERASE_SHARED_AGAIN_TITLE,
            message = BotInfoCopy.ERASE_SHARED_AGAIN_BODY,
            confirmLabel = BotInfoCopy.ERASE_SHARED_AGAIN_CONFIRM,
            confirmTag = BotInfoTags.MEMORY_ERASE_SHARED_AGAIN_CONFIRM,
            cancelTag = BOT_MEMORY_ERASE_SHARED_AGAIN_CANCEL,
            onDismiss = { confirmEraseSharedAgain = false },
            onConfirm = {
                confirmEraseSharedAgain = false
                onIntent(BotInfoIntent.EraseShared)
            },
        )
    }
    if (confirmRollback) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.MAINTENANCE_ROLLBACK_CONFIRM_TITLE,
            message = BotInfoCopy.MAINTENANCE_ROLLBACK_BODY,
            confirmLabel = BotInfoCopy.MAINTENANCE_ROLLBACK_CONFIRM,
            confirmTag = BotInfoTags.MAINTENANCE_ROLLBACK_CONFIRM,
            cancelTag = BOT_MEMORY_ROLLBACK_CANCEL,
            onDismiss = { confirmRollback = false },
            onConfirm = {
                confirmRollback = false
                state.snapshot?.maintenance?.let {
                    onIntent(BotInfoIntent.RollbackMaintenance(it.batchID))
                }
            },
        )
    }
}

@Composable
private fun BotMemorySection(
    title: String,
    documents: List<BotMemoryDocumentInfo>,
    root: String,
    onOpenDocument: (BotMemoryDocumentInfo) -> Unit,
    onForget: (BotMemoryDocumentInfo) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SessionSectionLabel(title)
    Column(Modifier.fillMaxWidth().padding(horizontal = tokens.geometry.pageOuterMarginH)) {
        if (documents.isEmpty()) {
            BasicText(
                text = BotInfoCopy.MEMORY_ROOT_EMPTY,
                style = type.secondary.copy(color = tokens.colors.textSecondary),
                modifier = Modifier.padding(vertical = tokens.spacing.iconText),
            )
        } else {
            BotMemoryTree.build(documents, root).forEach { item ->
                BotMemoryTreeRow(
                    item = item,
                    onOpenDocument = onOpenDocument,
                    onForget = onForget,
                )
            }
        }
    }
}

@Composable
private fun BotMemoryTreeRow(
    item: BotMemoryTreeItem,
    onOpenDocument: (BotMemoryDocumentInfo) -> Unit,
    onForget: (BotMemoryDocumentInfo) -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    if (item.isDirectory) {
        var expanded by remember(item.id) { mutableStateOf(true) }
        PdshDisclosure(
            expanded = expanded,
            onToggle = { expanded = !expanded },
            tag = BOT_MEMORY_FOLDER_PREFIX + item.id,
            header = {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = tokens.spacing.iconText),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
                ) {
                    PdshIconView(
                        PdshIcon.FOLDER,
                        BotInfoMetrics.DOCUMENT_ICON,
                        tokens.colors.textPrimary,
                        null,
                    )
                    BasicText(
                        text = item.name,
                        style = type.homeBody.copy(color = tokens.colors.textPrimary),
                    )
                }
            },
            body = {
                item.children.forEach { child ->
                    BotMemoryTreeRow(
                        item = child,
                        onOpenDocument = onOpenDocument,
                        onForget = onForget,
                    )
                }
            },
        )
    } else if (item.document != null) {
        val document = item.document
        Row(
            Modifier
                .fillMaxWidth()
                .testTag(BotInfoTags.memoryDocument(document.path)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier
                    .weight(1f)
                    .clickable(role = Role.Button, onClick = { onOpenDocument(document) })
                    .padding(vertical = tokens.spacing.iconText),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
            ) {
                PdshIconView(
                    PdshIcon.DOCUMENT,
                    BotInfoMetrics.DOCUMENT_ICON,
                    tokens.colors.textSecondary,
                    null,
                )
                Column(Modifier.weight(1f)) {
                    BasicText(
                        text = BotInfoFormat.fileName(document.path),
                        style = type.homeBody.copy(color = tokens.colors.textPrimary),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    BasicText(
                        text = BotInfoCopy.format(
                            BotInfoCopy.DOCUMENT_VERSION,
                            "version" to document.version,
                            "time" to BotInfoFormat.dateTime(document.updatedAt),
                            "evidence" to (
                                if (document.evidence.isEmpty()) {
                                    BotInfoCopy.DOCUMENT_NO_EVIDENCE
                                } else {
                                    BotInfoCopy.format(
                                        BotInfoCopy.DOCUMENT_COUNT,
                                        "count" to document.evidence.size,
                                    )
                                }
                                ),
                        ),
                        style = type.caption.copy(
                            fontSize = BotInfoMetrics.CAPTION_SIZE,
                            color = tokens.colors.textTertiary,
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            BasicText(
                text = BotUiStrings.INFO_MEMORY_FORGET,
                style = type.caption.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = { onForget(document) })
                    .padding(horizontal = tokens.spacing.iconText)
                    .testTag(BOT_MEMORY_FORGET_PREFIX + document.path),
            )
        }
    }
}

@Composable
private fun BotMemoryErasureSection(
    hasBotDocuments: Boolean,
    hasSharedDocuments: Boolean,
    onEraseBot: () -> Unit,
    onEraseShared: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    SessionSectionLabel(BotInfoCopy.DANGER_SECTION)
    Column(Modifier.fillMaxWidth().padding(horizontal = tokens.geometry.pageOuterMarginH)) {
        if (hasBotDocuments) {
            BasicText(
                text = BotUiStrings.INFO_MEMORY_ERASEBOT,
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onEraseBot)
                    .padding(vertical = tokens.spacing.iconText)
                    .testTag(BotInfoTags.MEMORY_ERASE),
            )
        }
        if (hasSharedDocuments) {
            BasicText(
                text = BotUiStrings.INFO_MEMORY_ERASESHARED,
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onEraseShared)
                    .padding(vertical = tokens.spacing.iconText)
                    .testTag(BotInfoTags.MEMORY_ERASE_SHARED),
            )
        }
    }
}

@Composable
private fun BotMaintenanceBatchCard(
    batch: BotMaintenanceBatchInfo,
    onRollback: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var detail by remember(batch.batchID) { mutableStateOf(false) }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = tokens.geometry.pageOuterMarginH)
            .testTag(BotInfoTags.MAINTENANCE_BATCH),
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            BasicText(
                text = BotInfoFormat.maintenanceStatusLabel(batch.status, batch.rolledBack),
                style = type.homeBody.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            BasicText(
                text = BotInfoFormat.dateTime(batch.finishedAt),
                style = type.caption.copy(
                    fontSize = BotInfoMetrics.CAPTION_SIZE,
                    color = tokens.colors.textTertiary,
                ),
            )
        }
        BasicText(
            text = BotInfoCopy.format(
                BotInfoCopy.MAINTENANCE_CHANGED,
                "count" to batch.changedDocuments,
                "result" to if (batch.checksPassed) {
                    BotInfoCopy.MAINTENANCE_CHECKED
                } else {
                    BotInfoCopy.MAINTENANCE_UNCHECKED
                },
            ),
            style = type.caption.copy(
                fontSize = BotInfoMetrics.CAPTION_SIZE,
                color = tokens.colors.textTertiary,
            ),
        )
        batch.changes.forEach { change ->
            BasicText(
                text = BotInfoFormat.maintenanceChangeLabel(change),
                style = type.caption.copy(
                    fontSize = BotInfoMetrics.CAPTION_SIZE,
                    color = tokens.colors.textSecondary,
                ),
            )
        }
        PdshDisclosure(
            expanded = detail,
            onToggle = { detail = !detail },
            tag = BotInfoTags.MAINTENANCE_DETAIL,
            header = {
                BasicText(
                    text = if (detail) {
                        BotInfoCopy.MAINTENANCE_COLLAPSE
                    } else {
                        BotInfoCopy.MAINTENANCE_DETAIL
                    },
                    style = type.secondary.copy(color = tokens.colors.textSecondary),
                    modifier = Modifier.padding(vertical = tokens.spacing.iconText),
                )
            },
            body = {
                Column(verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText)) {
                    batch.changes.forEach { change ->
                        BasicText(
                            text = BotInfoFormat.maintenanceChangeDetail(change),
                            style = type.code.copy(color = tokens.colors.textSecondary),
                        )
                    }
                    if (!batch.failureCode.isNullOrEmpty()) {
                        BasicText(
                            text = BotInfoCopy.format(
                                BotInfoCopy.MAINTENANCE_FAILURE,
                                "code" to batch.failureCode.orEmpty(),
                            ),
                            style = type.code.copy(color = tokens.colors.danger),
                        )
                    }
                    BasicText(
                        text = BotInfoCopy.format(
                            BotInfoCopy.MAINTENANCE_TOKENS,
                            "tokens" to batch.tokensUsed,
                        ),
                        style = type.code.copy(color = tokens.colors.textSecondary),
                    )
                }
            },
        )
        if (batch.canRollback) {
            BasicText(
                text = BotUiStrings.INFO_MAINTENANCE_ROLLBACK,
                style = type.secondary.copy(color = tokens.colors.danger),
                modifier = Modifier
                    .clickable(role = Role.Button, onClick = onRollback)
                    .padding(vertical = tokens.spacing.iconText)
                    .testTag(BotInfoTags.MAINTENANCE_ROLLBACK),
            )
        }
    }
}

@Composable
private fun BotMemoryDocumentPage(
    document: BotMemoryDocumentInfo,
    onBack: () -> Unit,
    onForget: () -> Unit,
    onErase: () -> Unit,
    modifier: Modifier,
    now: Long,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    var confirmErase by remember(document.path) { mutableStateOf(false) }
    var evidenceOpen by remember(document.path) { mutableStateOf(false) }
    var openVersion by remember(document.path) { mutableStateOf<Long?>(null) }

    PageFrame(
        title = BotInfoFormat.fileName(document.path),
        onBack = onBack,
        rootTag = BOT_MEMORY_DOCUMENT_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag(BOT_MEMORY_DOCUMENT_LIST),
            verticalArrangement = Arrangement.spacedBy(BotInfoMetrics.HEADER_GAP),
        ) {
            item(key = "body") {
                SessionSectionLabel(BotInfoCopy.DOCUMENT_TITLE)
                BasicText(
                    text = document.content.ifEmpty { BotInfoCopy.DOCUMENT_EMPTY },
                    style = type.homeBody.copy(color = tokens.colors.textPrimary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = tokens.geometry.pageOuterMarginH)
                        .testTag(BotInfoTags.MEMORY_DOCUMENT_CONTENT),
                )
                BasicText(
                    text = BotInfoCopy.format(BotInfoCopy.DOCUMENT_PATH, "path" to document.path),
                    style = type.caption.copy(
                        fontSize = BotInfoMetrics.CAPTION_SIZE,
                        color = tokens.colors.textTertiary,
                    ),
                    modifier = Modifier.padding(
                        horizontal = tokens.geometry.pageOuterMarginH,
                        vertical = tokens.spacing.iconText,
                    ),
                )
            }
            item(key = "sources") {
                SessionSectionLabel(BotInfoCopy.DOCUMENT_SOURCES)
                Column(Modifier.fillMaxWidth().padding(horizontal = tokens.geometry.pageOuterMarginH)) {
                    if (document.evidence.isEmpty()) {
                        BasicText(
                            text = BotInfoCopy.DOCUMENT_NO_SOURCES,
                            style = type.secondary.copy(color = tokens.colors.textSecondary),
                        )
                    } else {
                        PdshDisclosure(
                            expanded = evidenceOpen,
                            onToggle = { evidenceOpen = !evidenceOpen },
                            tag = BotInfoTags.MEMORY_DOCUMENT_EVIDENCE,
                            header = {
                                BasicText(
                                    text = BotInfoFormat.evidenceSummary(document.evidence),
                                    style = type.homeBody.copy(color = tokens.colors.textPrimary),
                                    modifier = Modifier.padding(vertical = tokens.spacing.iconText),
                                )
                            },
                            body = {
                                Column {
                                    document.evidence.forEach { reference ->
                                        BasicText(
                                            text = reference,
                                            style = type.code.copy(color = tokens.colors.textSecondary),
                                        )
                                    }
                                }
                            },
                        )
                    }
                    BotInfoValueRow(
                        label = BotInfoCopy.DOCUMENT_AUTHOR,
                        value = document.author.ifEmpty { BotInfoCopy.DOCUMENT_UNKNOWN },
                        tag = BOT_MEMORY_DOCUMENT_AUTHOR,
                    )
                    BotInfoValueRow(
                        label = BotInfoCopy.DOCUMENT_UPDATED,
                        value = BotInfoFormat.dateTime(document.updatedAt, now),
                        tag = BOT_MEMORY_DOCUMENT_UPDATED,
                    )
                }
            }
            item(key = "versions") {
                SessionSectionLabel(BotInfoCopy.DOCUMENT_VERSIONS)
                Column(
                    Modifier
                        .fillMaxWidth()
                        .padding(horizontal = tokens.geometry.pageOuterMarginH)
                        .testTag(BotInfoTags.MEMORY_DOCUMENT_VERSIONS),
                ) {
                    document.versions.sortedByDescending { it.version }.forEach { version ->
                        BotMemoryVersionRow(
                            version = version,
                            current = version.version == document.version,
                            open = openVersion == version.version,
                            onToggle = {
                                openVersion = if (openVersion == version.version) null else version.version
                            },
                        )
                    }
                }
            }
            item(key = "actions") {
                SessionSectionLabel(BotInfoCopy.DANGER_SECTION)
                Column(Modifier.fillMaxWidth().padding(horizontal = tokens.geometry.pageOuterMarginH)) {
                    BasicText(
                        text = BotInfoCopy.FORGET_ACTION,
                        style = type.secondary.copy(color = tokens.colors.danger),
                        modifier = Modifier
                            .clickable(role = Role.Button, onClick = onForget)
                            .padding(vertical = tokens.spacing.iconText)
                            .testTag(BotInfoTags.MEMORY_DOCUMENT_FORGET),
                    )
                    BasicText(
                        text = BotInfoCopy.ERASE_DOCUMENT,
                        style = type.secondary.copy(color = tokens.colors.danger),
                        modifier = Modifier
                            .clickable(role = Role.Button, onClick = { confirmErase = true })
                            .padding(vertical = tokens.spacing.iconText)
                            .testTag(BotInfoTags.MEMORY_DOCUMENT_ERASE),
                    )
                }
            }
        }
    }
    if (confirmErase) {
        BotInfoConfirmDialog(
            title = BotInfoCopy.ERASE_DOCUMENT_TITLE,
            message = BotInfoCopy.ERASE_DOCUMENT_BODY,
            confirmLabel = BotInfoCopy.ERASE_DOCUMENT_CONFIRM,
            confirmTag = BotInfoTags.MEMORY_DOCUMENT_ERASE_CONFIRM,
            cancelTag = BOT_MEMORY_DOCUMENT_ERASE_CANCEL,
            onDismiss = { confirmErase = false },
            onConfirm = {
                confirmErase = false
                onErase()
            },
        )
    }
}

@Composable
private fun BotMemoryVersionRow(
    version: BotMemoryVersionInfo,
    current: Boolean,
    open: Boolean,
    onToggle: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button, onClick = onToggle)
                .padding(vertical = tokens.spacing.iconText),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BasicText(
                text = BotInfoCopy.format(
                    BotInfoCopy.DOCUMENT_VERSION_ROW,
                    "version" to version.version,
                ),
                style = type.homeBody.copy(color = tokens.colors.textPrimary),
                modifier = Modifier.weight(1f),
            )
            if (current) {
                BasicText(
                    text = BotInfoCopy.DOCUMENT_CURRENT,
                    style = type.caption.copy(color = tokens.colors.textTertiary),
                )
            }
            Spacer(Modifier.size(tokens.spacing.iconText))
            BasicText(
                text = BotInfoFormat.dateTime(version.updatedAt),
                style = type.caption.copy(color = tokens.colors.textTertiary),
            )
            if (version.deleted) {
                Spacer(Modifier.size(tokens.spacing.iconText))
                PdshIconView(
                    PdshIcon.TRASH,
                    BotInfoMetrics.DOCUMENT_ICON,
                    tokens.colors.textTertiary,
                    null,
                )
            }
        }
        if (open) {
            BasicText(
                text = when {
                    version.deleted -> BotInfoCopy.DOCUMENT_VERSION_DELETED
                    version.content.isEmpty() -> BotInfoCopy.DOCUMENT_EMPTY
                    else -> version.content
                },
                style = type.homeBody.copy(
                    color = if (version.deleted) {
                        tokens.colors.textSecondary
                    } else {
                        tokens.colors.textPrimary
                    },
                ),
                modifier = Modifier
                    .background(tokens.colors.userBubble, androidx.compose.foundation.shape.RoundedCornerShape(
                        BotInfoMetrics.DETAIL_RADIUS,
                    ))
                    .padding(BotInfoMetrics.DETAIL_PADDING),
            )
        }
    }
}

/** One node of a memory root's document tree (`BotInfoPage.swift:1241-1280`). */
internal data class BotMemoryTreeItem(
    val id: String,
    val name: String,
    val isDirectory: Boolean,
    val document: BotMemoryDocumentInfo?,
    val children: List<BotMemoryTreeItem>,
)

/** Pure tree builder: the render starts below the root's folder row. */
internal object BotMemoryTree {
    fun build(
        documents: List<BotMemoryDocumentInfo>,
        root: String? = null,
    ): List<BotMemoryTreeItem> {
        if (root.isNullOrEmpty()) return buildAt(documents, "")
        val prefix = if (root.endsWith("/")) root else "$root/"
        val inside = documents.filter { it.path.startsWith(prefix) }
        val outside = documents.filterNot { it.path.startsWith(prefix) }
        return buildAt(inside, prefix) + buildAt(outside, "")
    }

    private fun buildAt(
        documents: List<BotMemoryDocumentInfo>,
        prefix: String,
    ): List<BotMemoryTreeItem> {
        val names = linkedMapOf<String, Pair<Boolean, BotMemoryDocumentInfo?>>()
        for (document in documents) {
            if (!document.path.startsWith(prefix)) continue
            val remainder = document.path.removePrefix(prefix)
            if (remainder.isEmpty()) continue
            val pieces = remainder.split('/', limit = 2)
            val head = pieces.firstOrNull().orEmpty()
            if (head.isEmpty()) continue
            val directory = pieces.size > 1
            names[head] = directory to (if (directory) null else document)
        }
        return names.keys.sorted().map { name ->
            val childPath = prefix + name
            val (directory, document) = names.getValue(name)
            if (directory) {
                BotMemoryTreeItem(
                    id = childPath,
                    name = name,
                    isDirectory = true,
                    document = null,
                    children = buildAt(documents, "$childPath/"),
                )
            } else {
                BotMemoryTreeItem(
                    id = childPath,
                    name = name,
                    isDirectory = false,
                    document = document,
                    children = emptyList(),
                )
            }
        }
    }
}

private const val BOT_MEMORY_ROOT: String = "bot.memory"
private const val BOT_MEMORY_EMPTY: String = "bot.memory.empty"
private const val BOT_MEMORY_FOLDER_PREFIX: String = "bot.memory.folder."
private const val BOT_MEMORY_FORGET_PREFIX: String = "bot.memory.forget."
private const val BOT_MEMORY_ERASE_CANCEL: String = "bot.memory.erase.cancel"
private const val BOT_MEMORY_ERASE_SHARED_CANCEL: String = "bot.memory.erase.shared.cancel"
private const val BOT_MEMORY_ERASE_SHARED_AGAIN_CANCEL: String = "bot.memory.erase.shared.again.cancel"
private const val BOT_MEMORY_ROLLBACK_CANCEL: String = "bot.memory.maintenance.rollback.cancel"
private const val BOT_MEMORY_DOCUMENT_ROOT: String = "bot.memory.document"
private const val BOT_MEMORY_DOCUMENT_LIST: String = "bot.memory.document.list"
private const val BOT_MEMORY_DOCUMENT_AUTHOR: String = "bot.memory.document.author"
private const val BOT_MEMORY_DOCUMENT_UPDATED: String = "bot.memory.document.updated"
private const val BOT_MEMORY_DOCUMENT_ERASE_CANCEL: String = "bot.memory.document.erase.cancel"
