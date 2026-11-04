// Phone permissions: the capability matrix and its three dimensions.
// SPDX-License-Identifier: MIT
//
// These tests are the accuracy contract, not a screenshot: the page's job is to
// tell the user what the phone allows, so the assertions are about what a row may
// *claim* and never about its pixels.
//
//  1. the matrix is the 23 iOS capabilities, in the baseline's group order;
//  2. an unread permission (`statuses == null`) never renders as granted — every
//     row says 未知 and no control is armed;
//  3. 已允许 appears only when the host reported `Authorized`;
//  4. each status maps to exactly the repair a user can perform (request, settings,
//     limited picker, blocked, always-on);
//  5. an unreported audit is not "no uses".
package com.phonedsh.ui.page

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PhonePermissionsPageStateTest {

    private fun state(
        statuses: Map<PhoneCapability, PhoneCapabilityStatus>? = null,
        enabled: Set<PhoneCapability> = emptySet(),
        audit: List<PhoneCapabilityAuditRecord>? = null,
        local: PhonePermissionsLocalState = PhonePermissionsLocalState(),
        requesting: PhoneCapability? = null,
    ): PhonePermissionsScreenState = PhonePermissionsScreenState.from(
        PhonePermissionsFacts(
            statuses = statuses,
            enabled = enabled,
            requesting = requesting,
            audit = audit,
        ),
        local,
    )

    private fun row(
        state: PhonePermissionsScreenState,
        capability: PhoneCapability,
    ): PhoneCapabilityRowState = state.groups
        .asSequence()
        .flatMap { it.rows }
        .first { it.capability == capability }

    @Test
    fun `the matrix is the 23 iOS capabilities in group order`() {
        val state = state()
        assertEquals(
            listOf("个人信息", "设备与传感器", "系统与通知", "文件与数据", "家庭与媒体"),
            state.groups.map { it.title },
        )
        assertEquals(listOf(5, 7, 5, 4, 2), state.groups.map { it.rows.size })
        assertEquals(23, PhoneCapability.matrix.size)
        assertEquals(
            listOf(
                "通讯录", "日历", "提醒事项", "健康", "照片",
                "相机", "麦克风", "语音识别", "定位", "运动与健身", "蓝牙", "本地网络",
                "通知", "面容确认", "专注模式", "实时活动", "快捷指令",
                "文件与文件夹", "剪贴板", "设备状态", "后台定位",
                "家庭", "音乐",
            ),
            PhoneCapability.matrix.map { it.title },
        )
        // The baseline's own grouping quirk (`PhoneCapability.swift:60`).
        assertEquals(PhoneCapabilityGroup.FILES_DATA, PhoneCapability.LOCATION_ALWAYS.group)
    }

    @Test
    fun `an unread permission never renders as granted`() {
        val state = state()
        assertFalse(state.statusesKnown)
        val rows = state.groups.flatMap { it.rows }
        assertEquals(23, rows.size)
        rows.forEach { row ->
            if (row.capability.readOnlyAlwaysOn) return@forEach
            assertNull(row.status)
            assertEquals("未知", row.statusLabel)
            assertFalse("${row.capability.title} must not be switched on", row.enabled)
            assertEquals(PhoneCapabilityAction.BLOCKED, row.action)
            // Unread is not refused: the row keeps full ink and says 未知 instead.
            assertFalse("${row.capability.title} must not be dimmed while unread", row.blocked)
        }
        // 设备状态 needs no grant: it stays 常开 and undimmed even when nothing is read.
        val device = row(state, PhoneCapability.DEVICE)
        assertEquals("常开", device.statusLabel)
        assertEquals(PhoneCapabilityAction.ALWAYS_ON, device.action)
        assertFalse(device.blocked)
    }

    @Test
    fun `authorized appears only when the host reported it`() {
        val state = state(
            statuses = mapOf(PhoneCapability.CAMERA to PhoneCapabilityStatus.Authorized),
            enabled = setOf(PhoneCapability.CAMERA),
        )
        val camera = row(state, PhoneCapability.CAMERA)
        assertEquals("已允许", camera.statusLabel)
        assertEquals(PhoneStatusTone.AUTHORIZED, camera.tone)
        assertTrue(camera.enabled)
        assertEquals(PhoneCapabilityAction.ENABLE, camera.action)
        // Every other capability stays undetermined: one grant is not a default, and
        // an untouched capability prints no status line at all.
        val microphone = row(state, PhoneCapability.MICROPHONE)
        assertEquals(PhoneCapabilityStatus.NotDetermined, microphone.status)
        assertNull(microphone.statusLabel)
        assertFalse(microphone.enabled)
    }

    @Test
    fun `a reported map without a capability is notDetermined, not granted`() {
        val state = state(statuses = mapOf(PhoneCapability.CAMERA to PhoneCapabilityStatus.Authorized))
        val microphone = row(state, PhoneCapability.MICROPHONE)
        assertEquals(PhoneCapabilityStatus.NotDetermined, microphone.status)
        assertNull("an untouched capability prints no status line", microphone.statusLabel)
        assertFalse(microphone.enabled)
        assertEquals(PhoneCapabilityAction.REQUEST, microphone.action)
    }

    @Test
    fun `the app switch is not the system grant`() {
        val grantedButOff = state(
            statuses = mapOf(PhoneCapability.CAMERA to PhoneCapabilityStatus.Authorized),
        )
        assertFalse(row(grantedButOff, PhoneCapability.CAMERA).enabled)

        val switchedOnButDenied = state(
            statuses = mapOf(PhoneCapability.CAMERA to PhoneCapabilityStatus.Denied),
            enabled = setOf(PhoneCapability.CAMERA),
        )
        assertFalse(
            "a denied capability cannot stay switched on",
            row(switchedOnButDenied, PhoneCapability.CAMERA).enabled,
        )
    }

    @Test
    fun `a denied capability opens settings instead of asking again`() {
        val denied = row(
            state(statuses = mapOf(PhoneCapability.CONTACTS to PhoneCapabilityStatus.Denied)),
            PhoneCapability.CONTACTS,
        )
        assertEquals("已拒绝", denied.statusLabel)
        assertEquals(PhoneStatusTone.DANGER, denied.tone)
        assertEquals(PhoneCapabilityAction.OPEN_SETTINGS, denied.action)
        assertTrue(denied.showsOpenSettings)
        assertFalse(denied.status!!.canRequest)
    }

    @Test
    fun `a limited photo library offers the picker`() {
        val photos = row(
            state(statuses = mapOf(PhoneCapability.PHOTOS to PhoneCapabilityStatus.Limited(3))),
            PhoneCapability.PHOTOS,
        )
        assertEquals("部分允许（3）", photos.statusLabel)
        assertEquals(PhoneStatusTone.WARNING, photos.tone)
        assertTrue(photos.showsLimitedPhotos)
        assertTrue(photos.status!!.permitsUse)

        // Only photos: a limited contacts grant has no Android picker to offer.
        val contacts = row(
            state(statuses = mapOf(PhoneCapability.CONTACTS to PhoneCapabilityStatus.Limited(2))),
            PhoneCapability.CONTACTS,
        )
        assertFalse(contacts.showsLimitedPhotos)
    }

    @Test
    fun `restricted and unavailable are blocked, not retryable`() {
        val restricted = row(
            state(statuses = mapOf(PhoneCapability.HEALTH to PhoneCapabilityStatus.Restricted)),
            PhoneCapability.HEALTH,
        )
        assertEquals("受系统限制", restricted.statusLabel)
        assertEquals(PhoneCapabilityAction.BLOCKED, restricted.action)
        assertTrue(restricted.blocked)
        assertFalse(restricted.status!!.canRequest)

        val unavailable = row(
            state(statuses = mapOf(PhoneCapability.MUSIC to PhoneCapabilityStatus.Unavailable)),
            PhoneCapability.MUSIC,
        )
        assertEquals("当前设备不可用", unavailable.statusLabel)
        assertEquals(PhoneCapabilityAction.BLOCKED, unavailable.action)
        assertTrue(unavailable.blocked)
    }

    @Test
    fun `the four special labels replace the case text`() {
        val statuses = mapOf(
            PhoneCapability.DEVICE to PhoneCapabilityStatus.Authorized,
            PhoneCapability.LOCAL_NETWORK to PhoneCapabilityStatus.NotDetermined,
            PhoneCapability.BIOMETRICS to PhoneCapabilityStatus.Authorized,
        )
        val state = state(statuses = statuses)
        assertEquals("常开", row(state, PhoneCapability.DEVICE).statusLabel)
        assertEquals("未验证 · 点击测试", row(state, PhoneCapability.LOCAL_NETWORK).statusLabel)
        assertEquals("已允许 · 写操作前确认", row(state, PhoneCapability.BIOMETRICS).statusLabel)

        val deniedNetwork = state(
            statuses = mapOf(PhoneCapability.LOCAL_NETWORK to PhoneCapabilityStatus.Denied),
        )
        assertEquals("可能已拒绝", row(deniedNetwork, PhoneCapability.LOCAL_NETWORK).statusLabel)
    }

    @Test
    fun `device status is always on and cannot be switched`() {
        val device = row(state(), PhoneCapability.DEVICE)
        assertEquals(PhoneCapabilityAction.ALWAYS_ON, device.action)
        // Always on is a fact, not a failure: it is not dimmed like a blocked row.
        assertFalse(device.blocked)
        assertTrue(device.capability.readOnlyAlwaysOn)
    }

    @Test
    fun `a request in flight disarms the row`() {
        val requesting = row(
            state(
                statuses = mapOf(PhoneCapability.CAMERA to PhoneCapabilityStatus.NotDetermined),
                requesting = PhoneCapability.CAMERA,
            ),
            PhoneCapability.CAMERA,
        )
        assertEquals(PhoneCapabilityAction.BLOCKED, requesting.action)
        assertTrue(requesting.requesting)
    }

    @Test
    fun `an empty audit is not an unread audit`() {
        assertNull("unread stays null", state(audit = null).audit)
        assertEquals(emptyList<PhoneCapabilityAuditRowState>(), state(audit = emptyList()).audit)
    }

    @Test
    fun `the audit keeps the last 20 records and names the capability`() {
        val records = (1..25).map { index ->
            PhoneCapabilityAuditRecord(
                tool = "contacts.search",
                capability = PhoneCapability.CONTACTS,
                at = "2026-01-0${(index % 9) + 1} 09:00",
                egress = index % 2 == 1,
                outcome = if (index == 3) "failed" else PhoneCapabilityAuditRecord.SUCCESS,
            )
        }
        val audit = state(audit = records).audit.orEmpty()
        assertEquals(PhonePermissionsScreenState.AUDIT_LIMIT, audit.size)
        assertEquals("通讯录 · 2026-01-02 09:00 · egress true", audit.first().detail)
        assertTrue(audit.first().succeeded)
        assertEquals("failed", audit.drop(1).firstOrNull { !it.succeeded }?.outcome)
    }

    @Test
    fun `the local state folds the confirmation and the disable notice`() {
        var local = PhonePermissionsLocalState()
        local = local.apply(PhonePermissionsUiEvent.Confirm(PhoneCapability.CONTACTS))
        assertEquals(PhoneCapability.CONTACTS, local.confirmation)
        val state = state(local = local)
        assertEquals("仅在你查询时读取联系人；电话和邮箱默认脱敏。", state.confirmationPurpose)

        local = local.apply(PhonePermissionsUiEvent.CancelConfirmation)
        assertNull(local.confirmation)

        local = local.apply(PhonePermissionsUiEvent.NotifyDisabled(PhoneCapability.CAMERA))
        assertEquals(PhoneCapability.CAMERA, local.disableNotice)
        assertEquals(
            "这只停用 Phone DSH 的相机能力，不会撤销系统权限。撤销或修改系统授权请前往系统设置。",
            state(local = local).disableNoticeBody,
        )

        local = local.apply(PhonePermissionsUiEvent.AcknowledgeDisable)
        assertNull(local.disableNotice)
    }

    @Test
    fun `the toggle keeps its own name, not the row title`() {
        val camera = row(state(), PhoneCapability.CAMERA)
        assertEquals("启用相机", camera.toggleDescription)
    }
}
