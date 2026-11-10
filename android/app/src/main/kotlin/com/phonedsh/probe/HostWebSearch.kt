// phone-dsh — :app: the 网页搜索 page's facts and writes.
// SPDX-License-Identifier: MIT
//
// The page (`android/lib/.../WebSearchSettingsPage.kt`) is a projection of these
// facts; its five write gestures arrive as `PdshHostAction`s and land in
// [WebSearchSettingsStore]. The facts never carry the key: only its state and at
// most four trailing characters. `spec/v1/gateway-independent-search.md` §5.

package com.phonedsh.probe

import com.phonedsh.account.TonoAccountKeySource
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.WebSearchFacts
import com.phonedsh.ui.page.WebSearchFailureReason
import com.phonedsh.ui.page.WebSearchMode

/**
 * Projects the stored settings and this launch's grant into the page facts.
 *
 * @param store the installed settings, or `null` when this host cannot write them.
 * @param officialEnabled whether this launch mounted the official follow-model grant.
 * @param modelConfigured whether the launch names a model service at all.
 * @param proxyRequested whether the launch allows host-injected keys.
 * @param engineStarted whether the engine runs.
 */
internal fun webSearchFacts(
    store: WebSearchSettingsStore?,
    officialEnabled: Boolean,
    modelConfigured: Boolean,
    proxyRequested: Boolean,
    engineStarted: FactState,
): WebSearchFacts {
    val modelSearchSupported = when {
        officialEnabled -> FactState.YES
        modelConfigured -> FactState.NO
        else -> FactState.UNKNOWN
    }
    if (store == null) {
        return WebSearchFacts(
            mode = WebSearchMode.FOLLOW_MODEL,
            modelSearchSupported = modelSearchSupported,
            noModelProfile = !modelConfigured,
            hasCredential = if (officialEnabled) FactState.YES else FactState.UNKNOWN,
            writable = FactState.NO,
            readOnlyReason = WEB_SEARCH_STORE_MISSING,
            engineStarted = engineStarted,
        )
    }
    val read = store.read()
    val searchApi = when (read) {
        WebSearchSettingsRead.Absent -> false
        is WebSearchSettingsRead.Stored -> read.settings.mode == WebSearchSettingsMode.SEARCH_API
        // An unreadable document is shown as the page's own service, so its
        // 删除这个搜索服务 row is there to recover from it.
        WebSearchSettingsRead.Unreadable -> true
    }
    if (!searchApi) {
        return WebSearchFacts(
            mode = WebSearchMode.FOLLOW_MODEL,
            modelSearchSupported = modelSearchSupported,
            noModelProfile = !modelConfigured,
            hasCredential = if (officialEnabled) FactState.YES else FactState.UNKNOWN,
            writable = FactState.YES,
            engineStarted = engineStarted,
        )
    }
    val keyState = store.keyState()
    val plan = WebSearchLaunchPlan.resolve(
        settings = read,
        independentKey = { keyState },
        accountCovers = { base -> TonoAccountKeySource.usesAccount(base, TonoAccountHost.activeSession()) },
        proxyRequested = proxyRequested,
        official = { null },
    )
    return WebSearchFacts(
        mode = WebSearchMode.SEARCH_API,
        modelSearchSupported = modelSearchSupported,
        noModelProfile = !modelConfigured,
        hasCredential = when (keyState) {
            is ApiKeyState.Valid -> FactState.YES
            ApiKeyState.Absent -> FactState.NO
            is ApiKeyState.Invalid, is ApiKeyState.Unreadable -> FactState.UNKNOWN
        },
        keyTail = store.keyTail(),
        launchWarning = (plan as? WebSearchLaunchPlan.Off)?.reason,
        failure = when {
            read == WebSearchSettingsRead.Unreadable -> WebSearchFailureReason.CONFIG_UNREADABLE
            keyState is ApiKeyState.Invalid || keyState is ApiKeyState.Unreadable ->
                WebSearchFailureReason.KEY_UNREADABLE
            else -> null
        },
        writable = FactState.YES,
        engineStarted = engineStarted,
    )
}

/**
 * Performs one 网页搜索 write, or returns `null` when [action] is not one.
 *
 * The returned line is the note bar's; it never contains the key.
 */
internal fun handleWebSearchAction(
    action: PdshHostAction,
    store: WebSearchSettingsStore?,
): WebSearchWriteResult? {
    val isWrite = action is PdshHostAction.SetWebSearchMode ||
        action is PdshHostAction.CommitWebSearchAddress ||
        action is PdshHostAction.CommitWebSearchKey ||
        action === PdshHostAction.ClearWebSearchKey ||
        action === PdshHostAction.RemoveWebSearchConfiguration
    if (!isWrite) return null
    if (store == null) return WebSearchWriteResult(WEB_SEARCH_STORE_MISSING, false)
    return when (action) {
        is PdshHostAction.SetWebSearchMode -> store.setMode(
            when (action.mode) {
                WebSearchMode.FOLLOW_MODEL -> WebSearchSettingsMode.FOLLOW_MODEL
                WebSearchMode.SEARCH_API -> WebSearchSettingsMode.SEARCH_API
            },
        )
        is PdshHostAction.CommitWebSearchAddress -> store.commitAddress(action.address)
        is PdshHostAction.CommitWebSearchKey -> store.commitKey(action.key)
        PdshHostAction.ClearWebSearchKey -> store.clearKey()
        PdshHostAction.RemoveWebSearchConfiguration -> store.remove()
        else -> null
    }
}

private const val WEB_SEARCH_STORE_MISSING: String =
    "本宿主没有安装网页搜索配置存储，网页搜索和抓取只能沿用官方 DeepSeek 模型服务的密钥。"
