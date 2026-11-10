// Tono 账号: SMS sign-in for the phoneDSH cloud service, and sign-out.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/TonoAccountPage.swift`.
// Contract: `spec/ui/v1/pages/tono-account.json`; behaviour:
// `spec/v1/tono-account.md` §3 (observable states).
//
// The host (`:app` TonoAccountHost) owns the session, the Keystore-wrapped
// refresh token and every request; this page only edits the phone and code
// drafts and sends 获取验证码 / 登录 / 退出登录. It never receives a token: the
// signed-in facts are a four-digit phone hint and the re-verification date.
package com.phonedsh.ui.page

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import com.phonedsh.ui.surface.SETTINGS_CLOSE_GLYPH
import com.phonedsh.ui.surface.SettingsFootnoteRow
import com.phonedsh.ui.surface.SettingsSectionLabel
import com.phonedsh.ui.surface.SettingsSubPageFrame
import com.phonedsh.ui.surface.settingsValueStyle
import com.phonedsh.ui.theme.LocalUiTokens

/** What the host says about the session; never a token or a full phone number. */
@Immutable
public data class TonoAccountFacts(
    /** False when this host has no account session wired; every control is then disabled. */
    public val available: Boolean = false,
    public val signedIn: Boolean = false,
    /** Last four digits of the signed-in number, or `null`. */
    public val phoneHint: String? = null,
    /** 需重新验证: the formatted re-verification date. */
    public val reverifyAt: String = "",
    /** A code was sent; the code field and 登录 appear (iOS `challenge != nil`). */
    public val codeSent: Boolean = false,
    public val busy: Boolean = false,
    /** The footer line: a notice, an error or the hint. */
    public val status: String = "",
    public val failed: Boolean = false,
    /** Bumped when the drafts must be cleared (after a sign-in). */
    public val revision: Int = 0,
) {
    override fun toString(): String = "TonoAccountFacts(available=$available, signedIn=$signedIn, busy=$busy)"
}

@Composable
public fun TonoAccountPage(
    facts: TonoAccountFacts,
    onBack: () -> Unit,
    onRequestCode: (String) -> Unit,
    onSignIn: (String) -> Unit,
    onSignOut: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var phone by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    LaunchedEffect(facts.revision) {
        phone = ""
        code = ""
    }
    val busy = facts.busy || !facts.available
    SettingsSubPageFrame(
        backGlyph = SETTINGS_CLOSE_GLYPH,
        largeTitle = "Tono 账号",
        onBack = onBack,
        rootTag = UiPageTags.TONO_ACCOUNT_ROOT,
        modifier = modifier,
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag(UiPageTags.TONO_ACCOUNT_LIST),
            verticalArrangement = Arrangement.Top,
        ) {
            if (facts.signedIn) {
                item(key = "account.header") { SettingsSectionLabel("当前账号") }
                item(key = "account.phone") {
                    InfoRow(title = "手机号", value = facts.phoneHint?.let { "尾号 $it" } ?: "已登录")
                }
                item(key = "account.reverify") { InfoRow(title = "需重新验证", value = facts.reverifyAt) }
                item(key = "signout") {
                    InfoRow(
                        title = "退出登录",
                        value = null,
                        tone = PageTone.DEGRADED,
                        enabled = !busy,
                        modifier = Modifier.testTag(UiPageTags.TONO_ACCOUNT_SIGN_OUT),
                        onClick = onSignOut,
                    )
                }
                item(key = "signout.footer") {
                    SettingsFootnoteRow(text = "退出后，云端模型和网页搜索改用你在「模型服务」和「网页搜索」里粘贴的密钥。")
                }
            } else {
                item(key = "login.header") { SettingsSectionLabel("手机号登录") }
                item(key = "login.phone") {
                    TonoTextField(phone, "手机号", KeyboardType.Phone, UiPageTags.TONO_ACCOUNT_PHONE) { phone = it }
                }
                item(key = "login.request") {
                    InfoRow(
                        title = "获取验证码",
                        value = null,
                        enabled = !busy,
                        modifier = Modifier.testTag(UiPageTags.TONO_ACCOUNT_REQUEST_CODE),
                        onClick = { onRequestCode(phone) },
                    )
                }
                if (facts.codeSent) {
                    item(key = "login.code") {
                        TonoTextField(code, "验证码", KeyboardType.NumberPassword, UiPageTags.TONO_ACCOUNT_CODE) { code = it }
                    }
                    item(key = "login.submit") {
                        InfoRow(
                            title = "登录",
                            value = null,
                            enabled = !busy,
                            modifier = Modifier.testTag(UiPageTags.TONO_ACCOUNT_SIGN_IN),
                            onClick = { onSignIn(code) },
                        )
                    }
                }
                item(key = "login.status") {
                    val tokens = LocalUiTokens.current
                    BasicText(
                        text = facts.status,
                        style = settingsValueStyle().copy(
                            color = if (facts.failed) tokens.colors.danger else tokens.colors.secondary,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag(UiPageTags.TONO_ACCOUNT_STATUS)
                            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
                    )
                }
            }
        }
    }
}

/** One plain input row; not an action for the structure gate. */
@Composable
private fun TonoTextField(
    value: String,
    placeholder: String,
    keyboard: KeyboardType,
    tag: String,
    onValueChange: (String) -> Unit,
) {
    val tokens = LocalUiTokens.current
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        textStyle = settingsValueStyle().copy(color = tokens.colors.primary),
        cursorBrush = SolidColor(tokens.colors.accent),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag)
            .heightIn(min = tokens.geometry.pageRowMinHeight)
            .padding(horizontal = tokens.geometry.pageOuterMarginH, vertical = tokens.spacing.iconText),
        decorationBox = { inner ->
            if (value.isEmpty()) {
                BasicText(text = placeholder, style = settingsValueStyle().copy(color = tokens.colors.tertiary))
            }
            inner()
        },
    )
}
