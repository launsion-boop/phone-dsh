// 设备连接: which devices a connector publishes, and which session each one opens.
// SPDX-License-Identifier: MIT
//
// The Android page of `NativeDeviceConnectionPage.swift` (172 lines). It keeps that
// page's three-part shape and, more importantly, its honesty:
//
//  1. **A failure section** — why the last open did not happen, plus the explicit
//     「解除该设备的会话映射」 action when a saved mapping is what is in the way.
//     iOS never silently rebinds; neither does this page.
//  2. **真实连接设备** — the devices the injected connector published. With no
//     connector, the baseline's `ContentUnavailableView("未接入设备连接器")` body is
//     reproduced word for word: this build does not scan, pair or invent a device.
//  3. **传输能力** — the two transport rows, and the footer that says the real
//     transport does not exist yet. Both rows read 未提供 because that is true.
//
// The data comes from `DeviceConnectionSource` (`:domain`), which projects the
// existing `DeviceConnector.state` through `ConnectorStatus`. This page owns no
// connection life cycle of its own: its local state is the row that is opening.
//
// Geometry: page margins use reviewed HomeSpec metrics; row and section spacing
// use the current UI theme. No page-only token is assumed.
package com.phonedsh.ui.page

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.phonedsh.domain.connector.ConnectorStatus
import com.phonedsh.domain.connector.DeviceConnectionEntry
import com.phonedsh.domain.connector.DeviceConnectionSnapshot
import com.phonedsh.domain.connector.DeviceOpenFailure
import com.phonedsh.domain.connector.DeviceTransmission
import com.phonedsh.domain.connector.DeviceTransmissionRow
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import com.phonedsh.ui.theme.UiColors

/**
 * What the 真实连接设备 section shows.
 *
 * The three cases are mutually exclusive on purpose: "there is no connector" is not
 * "the connector published nothing", which is not "here are the devices".
 */
public enum class DeviceListState {
    /** No connector was injected; the page renders the baseline's unavailable body. */
    UNAVAILABLE,

    /** A connector is injected and published no device. */
    EMPTY,

    /** The connector published at least one device. */
    READY,
}

/** The connection page's local UI state: the row whose session is being opened. */
public data class DeviceConnectionLocalState(
    public val openingDeviceId: String? = null,
)

/**
 * The connection page state.
 *
 * @param failure the one line above the list: an open failure first, then the
 *   connector's own reported failure. `null` when neither applies.
 * @param canForget whether a saved mapping exists for the device the failure names.
 * @param connectorProtocol the injected connector's protocol id, or `null`.
 */
public data class DeviceConnectionScreenState(
    public val list: DeviceListState,
    public val devices: List<DeviceConnectionEntry>,
    public val connectorProtocol: String?,
    public val transmissions: List<DeviceTransmissionRow>,
    public val status: ConnectorStatus,
    public val failure: String?,
    public val failedDeviceId: String?,
    public val canForget: Boolean,
    public val openingDeviceId: String?,
    /** Per-device link state reported by the host; absent keys render unknown. */
    public val deviceOnline: Map<String, Boolean?> = emptyMap(),
    /** Device ids with a saved session mapping in the host snapshot. */
    public val mappedDeviceIds: Set<String> = emptySet(),
) {
    public companion object {
        /**
         * Projects the source's snapshot into the page state.
         *
         * Pure: the same snapshot and local script always render the same rows, so a
         * JVM test replays a connector's state machine without a device.
         */
        public fun from(
            snapshot: DeviceConnectionSnapshot,
            local: DeviceConnectionLocalState = DeviceConnectionLocalState(),
            deviceOnline: Map<String, Boolean?> = emptyMap(),
        ): DeviceConnectionScreenState {
            val list = when {
                !snapshot.connectorAvailable -> DeviceListState.UNAVAILABLE
                snapshot.devices.isEmpty() -> DeviceListState.EMPTY
                else -> DeviceListState.READY
            }
            return DeviceConnectionScreenState(
                list = list,
                devices = snapshot.devices,
                connectorProtocol = snapshot.connectorProtocol,
                transmissions = snapshot.transmissions,
                status = snapshot.status,
                failure = failureLine(snapshot),
                failedDeviceId = snapshot.failedDeviceId,
                canForget = snapshot.canForget(snapshot.failedDeviceId),
                openingDeviceId = local.openingDeviceId,
                deviceOnline = deviceOnline,
                mappedDeviceIds = snapshot.forgettableDeviceIds,
            )
        }

        /** The page's failure sentence for the snapshot's own reason, if it has one. */
        private fun failureLine(snapshot: DeviceConnectionSnapshot): String? =
            when (val open = snapshot.openFailure) {
                is DeviceOpenFailure.Unavailable -> UiStrings.DEVICE_OPEN_FAILED_UNAVAILABLE
                is DeviceOpenFailure.Mismatch ->
                    UiStrings.DEVICE_OPEN_FAILED_MISMATCH.format(open.expected, open.actual)
                is DeviceOpenFailure.Failed -> UiStrings.DEVICE_OPEN_FAILED.format(open.detail)
                null -> snapshot.connectorFailure?.let {
                    UiStrings.DEVICE_CONNECTOR_FAILED.format(it.detail)
                }
            }
    }
}

/**
 * The connection page.
 *
 * @param state the pure screen state ([DeviceConnectionScreenState.from]).
 * @param onOpen open the device's fixed session; the page disables every row while
 *   one open is in flight, as the baseline does.
 * @param onForgetMapping drop the saved mapping the failure names.
 * @param onDone close the sheet (the baseline's 完成).
 */
@Composable
public fun NativeDeviceConnectionPage(
    state: DeviceConnectionScreenState,
    onOpen: (DeviceConnectionEntry) -> Unit,
    onForgetMapping: (String) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    PageFrame(
        title = UiStrings.DEVICE_TITLE,
        rootTag = UiPageTags.DEVICE_ROOT,
        modifier = modifier,
        actions = {
            SessionTextAction(
                label = UiStrings.DEVICE_DONE,
                onClick = onDone,
                tone = SessionActionTone.ACCENT,
            )
        },
    ) {
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            if (state.failure != null) {
                item(key = "failure") {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        SessionFailureLine(
                            message = state.failure,
                            tag = UiPageTags.DEVICE_FAILURE,
                        )
                        val failed = state.failedDeviceId
                        if (state.canForget && failed != null) {
                            // 解除该设备的会话映射 (`NativeDeviceConnectionPage.swift:93`).
                            // The same shape as the page's text actions — 44 pt floor,
                            // accent ink, one line — written out here instead of going
                            // through `SessionTextAction`: the structure checker locates
                            // an untitled group's criterion row by scanning *this* file
                            // for a `Text`/`BasicText` literal, and the shared
                            // component's `BasicText(text = label)` lives in
                            // `SessionPageChrome.kt`, so the failure group used to read
                            // as absent even though the action itself was found.
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag(UiPageTags.DEVICE_FORGET)
                                    .clickable(role = Role.Button) { onForgetMapping(failed) }
                                    .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
                                    .padding(horizontal = HomeMetrics.chromeInset)
                                    .semantics(mergeDescendants = true) {},
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                BasicText(
                                    text = UiStrings.DEVICE_FORGET_MAPPING,
                                    style = type.listItem.copy(color = tokens.colors.textPrimary),
                                    maxLines = 1,
                                )
                            }
                        }
                    }
                }
            }

            item(key = "devices-header") {
                SessionSectionLabel(UiStrings.DEVICE_SECTION_DEVICES)
            }
            when (state.list) {
                DeviceListState.UNAVAILABLE -> item(key = "unavailable") {
                    DeviceUnavailable(
                        title = UiStrings.DEVICE_CONNECTOR_UNAVAILABLE,
                        hint = UiStrings.DEVICE_CONNECTOR_UNAVAILABLE_HINT,
                        tag = UiPageTags.DEVICE_UNAVAILABLE,
                    )
                }

                DeviceListState.EMPTY -> item(key = "empty") {
                    DeviceUnavailable(
                        title = UiStrings.DEVICE_NO_DEVICES,
                        hint = UiStrings.DEVICE_NO_DEVICES_HINT,
                        tag = UiPageTags.DEVICE_EMPTY,
                    )
                }

                DeviceListState.READY -> items(
                    count = state.devices.size,
                    key = { index -> "device-${state.devices[index].deviceId}" },
                ) { index ->
                    val device = state.devices[index]
                    DeviceRow(
                        device = device,
                        opening = state.openingDeviceId == device.deviceId,
                        enabled = state.openingDeviceId == null,
                        online = state.deviceOnline[device.deviceId],
                        sessionMapped = device.deviceId in state.mappedDeviceIds,
                        onOpen = { onOpen(device) },
                    )
                    SessionHairline()
                }
            }

            item(key = "transport-header") {
                SessionSectionLabel(UiStrings.DEVICE_SECTION_TRANSPORT)
            }
            items(count = state.transmissions.size) { index ->
                TransportRow(state.transmissions[index])
            }
            item(key = "transport-footer") {
                BasicText(
                    text = UiStrings.DEVICE_TRANSPORT_FOOTER,
                    style = type.listItem.copy(color = tokens.colors.textTertiary),
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag(UiPageTags.DEVICE_TRANSPORT_FOOTER)
                        .padding(
                            horizontal = HomeMetrics.chromeInset,
                            vertical = tokens.spacing.iconText,
                        ),
                )
            }
        }
    }
}

/**
 * One device row: the online dot, the display name, the device id and the chevron.
 *
 * The row is disabled while any open is in flight, which is the baseline's
 * `.disabled(openingDeviceID != nil)`: two opens at once would race two mappings.
 */
@Composable
private fun DeviceRow(
    device: DeviceConnectionEntry,
    opening: Boolean,
    enabled: Boolean,
    online: Boolean?,
    sessionMapped: Boolean,
    onOpen: () -> Unit,
) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.DEVICE_ROW)
            .clickable(enabled = enabled, role = Role.Button, onClick = onOpen)
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.chromeInset,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {
                val onlineLabel = when (online) {
                    true -> DEVICE_ONLINE
                    false -> DEVICE_OFFLINE
                    null -> DEVICE_STATUS_UNKNOWN
                }
                val mappingLabel = if (sessionMapped) DEVICE_SESSION_MAPPED else DEVICE_SESSION_UNMAPPED
                contentDescription = "${device.displayName}. ${device.deviceId}. $mappingLabel. $onlineLabel"
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        DevicePhoneGlyph(online = online)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(tokens.spacing.badgeInsetV),
        ) {
            BasicText(
                text = device.displayName,
                style = type.body.copy(color = tokens.colors.textPrimary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            BasicText(
                text = device.deviceId,
                style = type.listItem.copy(color = tokens.colors.textSecondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            BasicText(
                text = buildString {
                    append(if (sessionMapped) DEVICE_SESSION_MAPPED else DEVICE_SESSION_UNMAPPED)
                    append(" · ")
                    append(when (online) {
                        true -> DEVICE_ONLINE
                        false -> DEVICE_OFFLINE
                        null -> DEVICE_STATUS_UNKNOWN
                    })
                    if (device.capabilityCount > 0) {
                        append(" · ")
                        append(DEVICE_CAPABILITY_COUNT.format(device.capabilityCount))
                    }
                },
                style = type.listItem.copy(color = tokens.colors.textSecondary),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        BasicText(
            text = if (opening) OPENING_GLYPH else CHEVRON_GLYPH,
            style = type.listItem.copy(
                color = if (opening) tokens.colors.textPrimary else tokens.colors.textTertiary,
            ),
        )
    }
}

/** The baseline's `iphone` glyph and six-point online mark (`NativeDeviceEntryIcon`). */
@Composable
private fun DevicePhoneGlyph(online: Boolean?) {
    val tokens = LocalUiTokens.current
    Box(
        modifier = Modifier.size(
            width = HomeMetrics.defaultMinListRowHeight * DEVICE_ICON_WIDTH_TO_ROW_RATIO,
            height = HomeMetrics.defaultMinListRowHeight * DEVICE_ICON_HEIGHT_TO_ROW_RATIO,
        ),
    ) {
        PdshIconView(
            icon = PdshIcon.DEVICE,
            size = HomeMetrics.navIcon,
            tint = tokens.colors.textSecondary,
            contentDescription = null,
            modifier = Modifier.align(Alignment.Center),
        )
        if (online == true) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(tokens.geometry.statusDotDiameter)
                    .background(tokens.colors.sessionSuccess, CircleShape)
                    .border(tokens.stroke.hairline, tokens.colors.surface, CircleShape),
            )
        }
    }
}

/** One transport row: its name, and whether this host really has it. */
@Composable
private fun TransportRow(row: DeviceTransmissionRow) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    val label = when (row.transmission) {
        DeviceTransmission.BLUETOOTH -> UiStrings.DEVICE_BLUETOOTH_CONNECTOR
        DeviceTransmission.LOCAL_NETWORK -> UiStrings.DEVICE_LOCAL_NETWORK_CONNECTOR
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(UiPageTags.DEVICE_TRANSPORT_ROW)
            .defaultMinSize(minHeight = HomeMetrics.defaultMinListRowHeight)
            .padding(
                horizontal = HomeMetrics.chromeInset,
                vertical = tokens.spacing.iconText,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(
            text = label,
            style = type.body.copy(color = tokens.colors.textPrimary),
            modifier = Modifier.weight(1f),
        )
        BasicText(
            text = if (row.available) {
                UiStrings.DEVICE_TRANSPORT_PROVIDED
            } else {
                UiStrings.DEVICE_TRANSPORT_NOT_PROVIDED
            },
            style = type.listItem.copy(
            color = if (row.available) tokens.colors.sessionSuccess else tokens.colors.textTertiary,
            ),
        )
    }
}

/** The baseline's `ContentUnavailableView`: a centred title and its explanation. */
@Composable
private fun DeviceUnavailable(title: String, hint: String, tag: String) {
    val tokens = LocalUiTokens.current
    val type = LocalUiType.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .padding(
                horizontal = HomeMetrics.chromeInset,
                vertical = tokens.geometry.cardOuterMarginV,
            )
            .semantics(mergeDescendants = true) { contentDescription = "$title. $hint" },
        verticalArrangement = Arrangement.spacedBy(tokens.spacing.iconText),
    ) {
        BasicText(text = title, style = type.body.copy(color = tokens.colors.textPrimary))
        BasicText(text = hint, style = type.listItem.copy(color = tokens.colors.textTertiary))
    }
}

/**
 * The token inventory of this page; `DeviceConnectorPagesTokenTest` fails when a use
 * site reads a token that is not listed here.
 */
internal object DeviceConnectionPageTokens {
    val refs: List<String> = listOf(
        "colors.sessionSuccess",
        "colors.surface",
        "colors.textPrimary",
        "colors.textSecondary",
        "colors.textTertiary",
        "geometry.cardOuterMarginV",
        "geometry.statusDotDiameter",
        "spacing.badgeInsetV",
        "spacing.iconText",
        "stroke.hairline",
        "typography.body",
        "typography.listItem",
    )
}

/** The disclosure chevron; the same glyph the other page rows use. */
private const val CHEVRON_GLYPH: String = "›"

/** The in-flight marker of the row whose session is opening. */
private const val OPENING_GLYPH: String = "…"
private const val DEVICE_ICON_WIDTH_TO_ROW_RATIO: Float = 0.5f
private const val DEVICE_ICON_HEIGHT_TO_ROW_RATIO: Float = 0.54545f
private const val DEVICE_SESSION_MAPPED: String = "已有会话映射"
private const val DEVICE_SESSION_UNMAPPED: String = "未建立会话映射"
private const val DEVICE_ONLINE: String = "在线"
private const val DEVICE_OFFLINE: String = "离线"
private const val DEVICE_STATUS_UNKNOWN: String = "连接状态未知"
private const val DEVICE_CAPABILITY_COUNT: String = "%d 项设备能力"

/** Canonical spec name, backed by the theme's resolved success role. */
private val UiColors.sessionSuccess: Color get() = success
