// SPDX-License-Identifier: MIT
//
// ConnectorsPage: the 发现 tab (`examples/probe-app/PhoneDSHProbe/ConnectorsPage.swift`).
//
// A first-level page listing the outside connections DSH has today — devices, web
// search and custom MCP servers — plus Gmail as an example of a service connector
// that cannot connect yet. Phone data (calendar, contacts…) is a permission, not a
// connector, and lives in 我的 › 手机权限. Picking a connector opens its detail
// sheet; the sheet's one action pushes the setup page once the sheet has gone, so
// the dismissal and the push never run over each other (`:94-108`).
//
// Structure mirrored from the baseline:
//   Section 连接器 { one row per DiscoverConnector }        (`:74-81`)
//   Section 更多   { 插件与工具 → NativeConfigurationPage }  (`:83-89`)
//   .sheet(item: selected) { ConnectorDetailSheet }        (`:94-108`)
//
// The page reads nothing from the engine: every row is a fixed entry whose
// destination is an existing route, so the host only supplies [onOpen].
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.launch
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ConnectorsMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.surface.SettingsCardGap
import com.phonedsh.ui.surface.SettingsGroupCard
import com.phonedsh.ui.surface.SettingsHairline
import com.phonedsh.ui.surface.SettingsNavBar
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageGroupedTopInset
import com.phonedsh.ui.surface.settingsLabelStyle
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.materialSheetColors

/** One entry of the 连接器 group (`DiscoverConnector`, `ConnectorsPage.swift:12`). */
public enum class DiscoverConnector(
    internal val icon: PdshIcon,
    /** The tile's glyph ink, the baseline's per-connector tint (`:24-31`). */
    internal val tint: Color,
) {
    GMAIL(PdshIcon.CHAT_BUBBLE, Color(0xFFEB4236)),
    DEVICES(PdshIcon.DEVICE_RADIO, Color(0xFF30B0C7)),
    WEB_SEARCH(PdshIcon.GLOBE, Color(0xFF33C759)),
    MCP(PdshIcon.DATABASE, Color.Unspecified),
    ;

    /** The example connector shows the pattern but cannot connect yet (`:61`). */
    public val isExample: Boolean get() = this == GMAIL

    internal fun title(languageId: String?): String = when (this) {
        DEVICES -> UiStrings.settingsNativeText(languageId, "设备", "Devices")
        WEB_SEARCH -> UiStrings.settingsNativeText(languageId, "网页搜索", "Web search")
        MCP -> UiStrings.settingsNativeText(languageId, "自定义 MCP 服务", "Custom MCP server")
        GMAIL -> "Gmail"
    }

    internal fun subtitle(languageId: String?): String = when (this) {
        DEVICES -> UiStrings.settingsNativeText(languageId, "通过蓝牙连接外设", "Peripherals over Bluetooth")
        WEB_SEARCH -> UiStrings.settingsNativeText(languageId, "让 DSH 搜索和读取网页", "Let DSH search and read the web")
        MCP -> UiStrings.settingsNativeText(languageId, "添加你自己的服务地址", "Add your own server")
        GMAIL -> UiStrings.settingsNativeText(languageId, "读取、撰写和发送邮件", "Read, write and send mail")
    }

    /** The gray pill on the row, naming what the sheet's action does (`:52-58`). */
    internal fun pillTitle(languageId: String?): String = when (this) {
        DEVICES, GMAIL -> UiStrings.settingsNativeText(languageId, "连接", "Connect")
        WEB_SEARCH -> UiStrings.settingsNativeText(languageId, "设置", "Set up")
        MCP -> UiStrings.settingsNativeText(languageId, "添加", "Add")
    }

    /** The sheet's primary action (`actionTitle`, `:243-251`). */
    internal fun actionTitle(languageId: String?): String = when (this) {
        DEVICES -> UiStrings.settingsNativeText(languageId, "连接设备", "Connect a device")
        WEB_SEARCH -> UiStrings.settingsNativeText(languageId, "设置网页搜索", "Set up web search")
        MCP -> UiStrings.settingsNativeText(languageId, "添加服务", "Add a server")
        GMAIL -> UiStrings.settingsNativeText(languageId, "连接", "Connect")
    }

    internal fun summary(languageId: String?): String = when (this) {
        DEVICES -> UiStrings.settingsNativeText(
            languageId,
            "连接附近的蓝牙外设，读取标准数据或控制提醒。局域网设备在「自定义 MCP 服务」中添加。",
            "Connect nearby Bluetooth peripherals to read standard data or control alerts. LAN devices are added under Custom MCP server.",
        )
        WEB_SEARCH -> UiStrings.settingsNativeText(
            languageId,
            "让 DSH 在对话里搜索网页、打开链接并读取内容，回答时附上来源。",
            "Let DSH search the web, open links and read pages, citing its sources.",
        )
        MCP -> UiStrings.settingsNativeText(
            languageId,
            "填入 MCP 服务的地址和密钥，DSH 就能调用这个服务提供的工具。",
            "Enter an MCP server's address and key so DSH can use the tools it offers.",
        )
        GMAIL -> UiStrings.settingsNativeText(
            languageId,
            "让 DSH 读取和搜索你的邮件，帮你整理收件箱、撰写和发送邮件。暂时还不能连接。",
            "Let DSH read and search your mail, tidy your inbox, write and send mail. Not available yet.",
        )
    }

    /**
     * 关于此连接器 (`aboutRows`, `:268-312`). The keys line is the one platform
     * fact that differs: iOS keeps secrets in the device keychain, this app in the
     * Android Keystore-backed store.
     */
    internal fun aboutRows(languageId: String?): List<Pair<String, String>> {
        fun t(zh: String, en: String) = UiStrings.settingsNativeText(languageId, zh, en)
        return when (this) {
            DEVICES -> listOf(
                t("蓝牙设备", "Bluetooth devices") to
                    t("只在蓝牙设备页主动扫描，连接后才会发现可用能力。",
                        "Scan is explicit on the Bluetooth devices page; capabilities appear only after connecting."),
                t("每次连接单独授权", "Authorized per connection") to
                    t("每次建立新连接后，需重新授权读取或提醒控制。",
                        "Each new connection needs read or alert permission again."),
            )
            WEB_SEARCH -> listOf(
                t("跟随模型或自定义来源", "Model or custom source") to
                    t("默认使用模型自带的搜索，也可以填入自己的搜索服务。",
                        "Uses the model's own search by default, or a search service you add."),
                t("密钥只存在本机", "Keys stay on this phone") to
                    t("搜索服务的密钥保存在本机的 Android 密钥库里。",
                        "Search service keys are kept in this phone's Android Keystore."),
            )
            MCP -> listOf(
                t("标准 MCP 协议", "Standard MCP") to
                    t("支持通过 HTTP 访问的 MCP 服务，可以添加多个。",
                        "Works with MCP servers reachable over HTTP; add as many as you need."),
                t("密钥只存在本机", "Keys stay on this phone") to
                    t("认证信息只写入本机的 Android 密钥库，不会上传。",
                        "Credentials are written to this phone's Android Keystore only."),
            )
            GMAIL -> listOf(
                t("读取和搜索邮件", "Read and search mail") to
                    t("按发件人、主题或时间查找邮件，整理要点。",
                        "Find mail by sender, subject or date and pull out what matters."),
                t("撰写和发送邮件", "Write and send mail") to
                    t("按你的意思写新邮件或回复，直接发送。",
                        "Write new mail or replies the way you want and send them."),
            )
        }
    }
}

/** Test tags of the 发现 page. */
public object ConnectorsPageTags {
    public const val ROOT: String = "pdsh.connectors.root"
    public const val LIST: String = "pdsh.connectors.list"
    public const val ROW_PREFIX: String = "pdsh.connectors.row."
    public const val PLUGINS_TOOLS: String = "pdsh.connectors.pluginsTools"
    public const val SHEET: String = "pdsh.connectors.sheet"
    public const val SHEET_ACTION: String = "pdsh.connectors.sheet.action"
}

/**
 * The 发现 tab.
 *
 * @param onOpen a connector's sheet action was taken; the host pushes that
 *   connector's setup page (设备 → 蓝牙设备, 网页搜索 → 网页搜索设置,
 *   自定义 MCP 服务 → MCP). The example connector never calls it.
 * @param onOpenPluginsTools 更多 › 插件与工具 (`NativeConfigurationPage`).
 * @param languageId the stored language preference, for the bilingual copy.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun ConnectorsPage(
    onOpen: (DiscoverConnector) -> Unit,
    onOpenPluginsTools: () -> Unit,
    modifier: Modifier = Modifier,
    languageId: String? = null,
) {
    val tokens = LocalUiTokens.current
    var selected by rememberSaveable { mutableStateOf<DiscoverConnector?>(null) }
    val scope = rememberCoroutineScope()
    Column(
        modifier = modifier
            .fillMaxSize()
            .background(tokens.colors.page)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
            .testTag(ConnectorsPageTags.ROOT),
    ) {
        SettingsNavBar(title = UiStrings.settingsNativeText(languageId, "发现", "Discover"))
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(ConnectorsPageTags.LIST),
            contentPadding = PaddingValues(top = SettingsSubPageGroupedTopInset, bottom = ConnectorsMetrics.listBottom),
            verticalArrangement = Arrangement.spacedBy(SettingsCardGap),
        ) {
            item(key = "connectors") {
                Column {
                    SettingsSectionLabel(title = UiStrings.settingsNativeText(languageId, "连接器", "Connectors"))
                    SettingsGroupCard {
                        DiscoverConnector.entries.forEachIndexed { index, connector ->
                            ConnectorRow(
                                connector = connector,
                                languageId = languageId,
                                dividerBelow = index != DiscoverConnector.entries.lastIndex,
                                onSelect = { selected = connector },
                            )
                        }
                    }
                }
            }
            item(key = "more") {
                Column {
                    SettingsSectionLabel(title = UiStrings.settingsNativeText(languageId, "更多", "More"))
                    SettingsGroupCard {
                        ConnectorLinkRow(
                            label = UiStrings.settingsNativeText(languageId, "插件与工具", "Plugins and tools"),
                            icon = PdshIcon.PUZZLE,
                            onClick = onOpenPluginsTools,
                            modifier = Modifier.testTag(ConnectorsPageTags.PLUGINS_TOOLS),
                        )
                    }
                }
            }
        }
    }
    val connector = selected
    if (connector != null) {
        val palette = materialSheetColors(tokens)
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
        ModalBottomSheet(
            // Tapping outside or swiping it away closes it, so it has no close
            // button (`:192-194`).
            onDismissRequest = { selected = null },
            sheetState = sheetState,
            modifier = Modifier.testTag(ConnectorsPageTags.SHEET),
            containerColor = palette.container,
            contentColor = palette.content,
        ) {
            ConnectorDetailSheet(
                connector = connector,
                languageId = languageId,
                // The push waits for the sheet to finish leaving (`pendingPush` +
                // `onDismiss`, `:94-100`), so the two never animate over each other.
                onOpen = {
                    scope.launch { sheetState.hide() }.invokeOnCompletion {
                        selected = null
                        onOpen(connector)
                    }
                },
            )
        }
    }
}

/** Rounded tile with a tinted glyph, the connector's icon (`ConnectorTile`, `:155`). */
@Composable
private fun ConnectorTile(connector: DiscoverConnector, size: androidx.compose.ui.unit.Dp) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier
            .size(size)
            .background(tokens.colors.userBubble, RoundedCornerShape(size * ConnectorsMetrics.TILE_RADIUS_RATIO)),
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon = connector.icon,
            size = size * ConnectorsMetrics.TILE_GLYPH_RATIO,
            tint = if (connector.tint == Color.Unspecified) tokens.colors.textPrimary else connector.tint,
            contentDescription = null,
        )
    }
}

/** One 连接器 row: tile, name and subtitle, the gray pill (`row(_:)`, `:126`). */
@Composable
private fun ConnectorRow(
    connector: DiscoverConnector,
    languageId: String?,
    dividerBelow: Boolean,
    onSelect: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(role = Role.Button, onClick = onSelect)
                .testTag(ConnectorsPageTags.ROW_PREFIX + connector.name.lowercase())
                .semantics(mergeDescendants = true) {}
                .padding(horizontal = com.phonedsh.ui.SettingsMetrics.ROW_CONTENT_INSET_PT.dp, vertical = ConnectorsMetrics.rowPaddingV),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(ConnectorsMetrics.rowSpacing),
        ) {
            ConnectorTile(connector, ConnectorsMetrics.rowTile)
            Column(modifier = Modifier.weight(1f)) {
                BasicText(
                    text = connector.title(languageId),
                    style = type.body.copy(color = tokens.colors.textPrimary),
                )
                BasicText(
                    text = connector.subtitle(languageId),
                    style = type.caption.copy(color = tokens.colors.textPlaceholder, fontSize = ConnectorsMetrics.subtitleSize),
                    maxLines = 1,
                )
            }
            BasicText(
                text = connector.pillTitle(languageId),
                style = type.body.copy(
                    color = tokens.colors.textPrimary,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = ConnectorsMetrics.pillTextSize,
                ),
                modifier = Modifier
                    .background(tokens.colors.userBubble, CircleShape)
                    .heightIn(min = ConnectorsMetrics.pillHeight)
                    .padding(horizontal = ConnectorsMetrics.pillPaddingH)
                    .wrapContentHeight(),
            )
        }
        if (dividerBelow) {
            SettingsHairline(Modifier.align(Alignment.BottomCenter).padding(start = ConnectorsMetrics.rowSeparatorInset))
        }
    }
}

/** A plain navigation row inside a card: icon, label, chevron. */
@Composable
private fun ConnectorLinkRow(
    label: String,
    icon: PdshIcon,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = com.phonedsh.ui.SettingsMetrics.GROUPED_LIST_MIN_ROW_HEIGHT_PT.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = tokens.geometry.pageOuterMarginH),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PdshIconView(
            icon = icon,
            size = com.phonedsh.ui.HomeMetrics.composerIcon,
            tint = tokens.colors.textPrimary,
            contentDescription = null,
        )
        BasicText(
            text = label,
            style = settingsLabelStyle().copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f).padding(start = tokens.spacing.iconText),
        )
        PdshIconView(
            icon = PdshIcon.CHEVRON_RIGHT,
            size = com.phonedsh.ui.SettingsMetrics.CHEVRON_HEIGHT_PT.dp,
            tint = tokens.colors.textPlaceholder,
            contentDescription = null,
        )
    }
}

/**
 * One connector's sheet: icon, name, the one action, what it is for, then
 * 关于此连接器 (`ConnectorDetailSheet`, `:191`). The example connector's action
 * is a disabled 即将支持.
 */
@Composable
private fun ConnectorDetailSheet(
    connector: DiscoverConnector,
    languageId: String?,
    onOpen: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(bottom = ConnectorsMetrics.sheetBodyBottom),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.heightIn(min = ConnectorsMetrics.sheetTileTop))
        ConnectorTile(connector, ConnectorsMetrics.sheetTile)
        BasicText(
            text = connector.title(languageId),
            style = type.headline.copy(color = tokens.colors.textPrimary, fontWeight = FontWeight.Bold, fontSize = ConnectorsMetrics.sheetTitleSize),
            modifier = Modifier.padding(top = ConnectorsMetrics.sheetTitleTop),
        )
        if (connector.isExample) {
            Button(
                onClick = {},
                enabled = false,
                modifier = Modifier.padding(top = ConnectorsMetrics.sheetActionTop)
                    .widthIn(max = ConnectorsMetrics.sheetActionMaxWidth).fillMaxWidth()
                    .testTag(ConnectorsPageTags.SHEET_ACTION),
            ) {
                Text(text = UiStrings.settingsNativeText(languageId, "即将支持", "Coming soon"))
            }
        } else {
            Button(
                onClick = onOpen,
                colors = ButtonDefaults.buttonColors(
                    containerColor = tokens.colors.textPrimary,
                    contentColor = tokens.colors.page,
                ),
                modifier = Modifier.padding(top = ConnectorsMetrics.sheetActionTop)
                    .widthIn(max = ConnectorsMetrics.sheetActionMaxWidth).fillMaxWidth()
                    .testTag(ConnectorsPageTags.SHEET_ACTION),
            ) {
                Text(text = connector.actionTitle(languageId))
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = tokens.geometry.pageOuterMarginH)
                .padding(top = ConnectorsMetrics.sheetBodyTop),
            verticalArrangement = Arrangement.spacedBy(ConnectorsMetrics.sheetBodySpacing),
        ) {
            BasicText(
                text = connector.summary(languageId),
                style = type.body.copy(color = tokens.colors.textPlaceholder, fontSize = ConnectorsMetrics.sheetBodyTextSize),
            )
            BasicText(
                text = UiStrings.settingsNativeText(languageId, "关于此连接器", "About this connector"),
                style = type.body.copy(color = tokens.colors.textPlaceholder, fontSize = ConnectorsMetrics.sheetBodyTextSize, fontWeight = FontWeight.Medium),
                modifier = Modifier.padding(top = ConnectorsMetrics.aboutHeaderTop),
            )
            val rows = connector.aboutRows(languageId)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(tokens.colors.surface, RoundedCornerShape(ConnectorsMetrics.aboutCardRadius)),
            ) {
                rows.forEachIndexed { index, (title, detail) ->
                    if (index > 0) SettingsHairline(Modifier.padding(start = ConnectorsMetrics.aboutRowPadding))
                    Column(Modifier.fillMaxWidth().padding(ConnectorsMetrics.aboutRowPadding)) {
                        BasicText(
                            text = title,
                            style = type.body.copy(color = tokens.colors.textPrimary, fontWeight = FontWeight.SemiBold),
                        )
                        BasicText(
                            text = detail,
                            style = type.caption.copy(color = tokens.colors.textPlaceholder),
                            modifier = Modifier.padding(top = ConnectorsMetrics.aboutRowSpacing),
                        )
                    }
                }
            }
        }
    }
}
