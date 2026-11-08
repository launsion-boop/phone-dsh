// SPDX-License-Identifier: MIT
//
// Which web-search grant one launch mounts (`spec/v1/gateway-independent-search.md`
// §3). The independent mode replaces the official follow-model grant; an
// independent setup that is incomplete or unreadable leaves both tools off, never
// falls back to the model key.

package com.phonedsh.probe

import com.phonedsh.gateway.IndependentSearchWebTools

internal sealed interface WebSearchLaunchPlan {
    /** The Worker entries this plan publishes; empty when the tools stay off. */
    val environment: Map<String, String>

    /** Follow-model with the official model key ([OfficialWebSearchLaunch]). */
    data class Official(val launch: OfficialWebSearchLaunch) : WebSearchLaunchPlan {
        override val environment: Map<String, String> get() = launch.environment
    }

    /** The person's own service: canonical [base], independent key. */
    data class Independent(val base: String) : WebSearchLaunchPlan {
        override val environment: Map<String, String> get() = IndependentSearchWebTools.workerEnvironment(base)
    }

    /** No web tools; [reason] is the page's launch line, `null` for plain follow-model. */
    data class Off(val reason: String?) : WebSearchLaunchPlan {
        override val environment: Map<String, String> get() = emptyMap()
    }

    companion object {
        /**
         * @param settings the stored independent document.
         * @param independentKey reads the independent key's state (only in search-api mode).
         * @param proxyRequested false when the launch forbids host-injected keys.
         * @param official the follow-model decision, computed only when it applies.
         */
        fun resolve(
            settings: WebSearchSettingsRead,
            independentKey: () -> ApiKeyState,
            proxyRequested: Boolean,
            official: () -> OfficialWebSearchLaunch?,
        ): WebSearchLaunchPlan {
            val stored = when (settings) {
                WebSearchSettingsRead.Absent -> null
                is WebSearchSettingsRead.Stored -> settings.settings
                WebSearchSettingsRead.Unreadable -> return Off(UNREADABLE)
            }
            if (stored == null || stored.mode == WebSearchSettingsMode.FOLLOW_MODEL) {
                return official()?.let(::Official) ?: Off(null)
            }
            if (!proxyRequested) return Off(NO_HOST_EDGE)
            val base = stored.baseUrl.takeIf { IndependentSearchWebTools.canonicalBase(it) == it }
                ?: return Off(NO_ADDRESS)
            return when (independentKey()) {
                is ApiKeyState.Valid -> Independent(base)
                ApiKeyState.Absent -> Off(NO_KEY)
                is ApiKeyState.Invalid, is ApiKeyState.Unreadable -> Off(KEY_UNUSABLE)
            }
        }

        const val UNREADABLE: String = "网页搜索配置无法读取，网页搜索和网页读取不会启用"
        const val NO_HOST_EDGE: String = "本次启动没有宿主注入密钥的通道，自己填的搜索服务不会启用"
        const val NO_ADDRESS: String = "还没有保存搜索服务地址，网页搜索和网页读取不会启用"
        const val NO_KEY: String = "还没有保存这个搜索服务的密钥，网页搜索和网页读取不会启用"
        const val KEY_UNUSABLE: String = "搜索服务的密钥无法读取，网页搜索和网页读取不会启用"
    }
}
