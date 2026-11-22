// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import android.util.AtomicFile
import com.phonedsh.gateway.EgressPolicy
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.GatewayTransport
import com.phonedsh.gateway.HttpUrlConnectionGatewayTransport
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.gateway.GatewayUrl
import com.phonedsh.ui.page.EgressAllowListFacts
import com.phonedsh.ui.page.EgressRule
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.egressEntryValue
import com.phonedsh.ui.page.validateEgressEntry
import java.io.File
import java.io.FileNotFoundException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Persist and publish one snapshot for both the settings UI and gateway redirect checks. */
internal class NetworkAccessSettings(file: File) : EgressPolicy {
    private data class Saved(val hosts: List<String>, val allowAll: Boolean)
    private val disk = AtomicFile(file)
    private val current = MutableStateFlow(readFacts())
    val facts = current.asStateFlow()

    fun readGateway(transport: GatewayTransport = HttpUrlConnectionGatewayTransport()) = GatewaySession(
        transport = transport,
        credentialProvider = GatewayCredentialProvider { GatewayCredential.None },
        egress = this,
        anonymousReadsOnly = true,
    )

    override fun permits(url: GatewayUrl): Boolean {
        val state = current.value
        val rules = state.rules ?: return false
        if (!url.isHttp || state.failure != null) return false
        return state.allowAllOverride == true || rules.any { GatewayHostRule.hostMatches(url.host, it.host) }
    }

    override fun admitsMcpGrant(url: GatewayUrl) = false

    @Synchronized fun refresh() { current.value = readFacts() }
    fun add(raw: String) = edit { saved ->
        val host = egressEntryValue(raw)
        if (saved.allowAll || validateEgressEntry(host, saved.hosts) != null) saved
        else saved.copy(hosts = saved.hosts + host)
    }
    fun remove(host: String) = edit { it.copy(hosts = it.hosts - host) }
    fun toggle(on: Boolean) = edit {
        if (it.allowAll && !on && it.hosts.isEmpty()) Saved(DEFAULT_HOSTS, false)
        else it.copy(allowAll = on)
    }
    fun restore() = edit { Saved(DEFAULT_HOSTS, false) }

    @Synchronized private fun edit(change: (Saved) -> Saved) {
        try {
            val before = read()
            val after = change(before)
            if (before != after) {
                val obj = JSONObject().put("version", 1).put("allowAll", after.allowAll)
                    .put("hosts", JSONArray(after.hosts))
                val stream = disk.startWrite()
                try {
                    stream.write(obj.toString().toByteArray(Charsets.UTF_8))
                    disk.finishWrite(stream)
                } catch (error: Exception) {
                    disk.failWrite(stream)
                    throw error
                }
            }
            val confirmed = read()
            check(confirmed == after)
            current.value = confirmed.toFacts()
        } catch (_: Exception) {
            current.value = unavailable("无法保存网络访问规则。请重试以重新读取。")
        }
    }

    private fun readFacts() = try { read().toFacts() }
        catch (_: Exception) { unavailable("无法读取本机网络访问规则。请重试。") }

    private fun unavailable(message: String) = EgressAllowListFacts(failure = message)
    private fun Saved.toFacts() = EgressAllowListFacts(
        rules = hosts.map { EgressRule(id = it, host = it) },
        writable = FactState.YES,
        allowAllOverride = allowAll,
    )

    private fun read(): Saved {
        val bytes = try { disk.readFully() } catch (error: FileNotFoundException) {
            if (disk.baseFile.exists() || File(disk.baseFile.path + ".bak").exists() ||
                disk.baseFile.parentFile?.let { it.isDirectory && it.canRead() && it.canExecute() } != true) throw error
            return Saved(DEFAULT_HOSTS, false)
        }
        val obj = JSONObject(bytes.toString(Charsets.UTF_8))
        require(obj.get("version") == 1)
        val allowAll = obj.get("allowAll") as Boolean
        val entries = obj.getJSONArray("hosts")
        val hosts = LinkedHashSet<String>()
        for (i in 0 until entries.length()) {
            val entry = entries.get(i) as String
            require(egressEntryValue(entry) == entry && validateEgressEntry(entry, hosts) == null)
            hosts.add(entry)
        }
        return Saved(hosts.toList(), allowAll)
    }

    companion object {
        internal val DEFAULT_HOSTS = listOf(
            "wttr.in", "api.open-meteo.com", "geocoding-api.open-meteo.com", "api.github.com",
            "raw.githubusercontent.com", "github.com", "pypi.org", "files.pythonhosted.org",
            "registry.npmjs.org", "cdn.jsdelivr.net", "unpkg.com", "en.wikipedia.org",
            "zh.wikipedia.org", "example.com",
        )
        private var instance: NetworkAccessSettings? = null
        @Synchronized fun get(context: Context): NetworkAccessSettings =
            instance ?: NetworkAccessSettings(File(context.applicationContext.filesDir, "egress-settings.json"))
                .also { instance = it }
    }
}
