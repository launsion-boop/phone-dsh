// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import com.phonedsh.ui.page.AndroidAdbCandidate
import com.phonedsh.ui.page.AndroidAdbCandidateKind
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Foreground TV discovery for the Android ADB page: bounded TCP probes of the
 * current Wi-Fi subnet.
 *
 * Platform difference from iOS, stated so it is not mistaken for parity: iOS
 * also browses Bonjour (`_androidtvremote2._tcp`, `_googlecast._tcp`,
 * `_airplay._tcp`, `_roku-rcp._tcp`) through NetServiceBrowser. This first
 * Android version deliberately has no NsdManager catalog: a DNS-SD hit would
 * give a name but not the ADB endpoint the page subsequently dials, and some
 * devices keep NsdManager callbacks alive after the page is gone. Only a port
 * that actually accepted a connection is evidence here, so the page never
 * displays a Bonjour name the host did not observe.
 *
 * Bounds are hard: IPv4 addresses of the Wi-Fi interface only (cellular, VPN,
 * loopback and link-local are excluded), at most [MAX_HOSTS] addresses, the
 * ADB port first, [CONCURRENCY] simultaneous dials, [CONNECT_TIMEOUT_MS] per
 * dial and an [OVERALL_BUDGET_MS] budget for the whole pass. A cancel stops new
 * dials immediately; a dial already inside `connect()` ends within its 400 ms
 * timeout. Partial results are returned, never a fabricated one.
 */
internal class AndroidTvDiscovery(context: Context) {
    private val context: Context = context.applicationContext

    /** One bounded scan; the caller owns cancellation (this function is cooperative). */
    suspend fun scan(): List<AndroidAdbCandidate> = withContext(Dispatchers.IO) {
        val targets = wifiTargets().take(MAX_HOSTS)
        if (targets.isEmpty()) return@withContext emptyList()

        // Port-major so the ADB port is probed across the subnet first: an 8 s
        // budget then still favours 5555 evidence, which is the only evidence
        // that makes a candidate 可控制.
        val jobs = ArrayList<ProbeJob>(targets.size * PORTS.size)
        for (port in PORTS) {
            for (target in targets) jobs.add(ProbeJob(target.network, target.host, port))
        }

        val openPorts = ConcurrentHashMap<String, MutableSet<Int>>()
        val next = AtomicInteger()
        // A timeout returns the hits collected so far; the workers are cancelled
        // by withTimeoutOrNull and stop at their next isActive check.
        withTimeoutOrNull(OVERALL_BUDGET_MS) {
            coroutineScope {
                repeat(minOf(CONCURRENCY, jobs.size)) {
                    launch {
                        while (isActive) {
                            val index = next.getAndIncrement()
                            if (index >= jobs.size) break
                            val job = jobs[index]
                            if (probe(job)) {
                                openPorts.computeIfAbsent(job.host) { ConcurrentHashMap.newKeySet() }.add(job.port)
                            }
                        }
                    }
                }
            }
        }
        candidates(openPorts)
    }

    /** One TCP connect. [Network.bindSocket] keeps the dial on Wi-Fi, never the VPN route. */
    private fun probe(job: ProbeJob): Boolean {
        val socket = Socket()
        return try {
            job.network.bindSocket(socket)
            socket.connect(InetSocketAddress(job.host, job.port), CONNECT_TIMEOUT_MS)
            true
        } catch (_: IOException) {
            false
        } catch (_: SecurityException) {
            false
        } finally {
            runCatching { socket.close() }
        }
    }

    /**
     * Every IPv4 host address on a Wi-Fi network this phone currently has.
     *
     * ConnectivityManager supplies the network so the socket can be bound to
     * it; NetworkInterface supplies the address/prefix. The Wi-Fi network's own
     * capabilities are checked again for VPN/cellular transport, and the link
     * name must be `wlan*` so a tunnel or a cellular interface cannot widen the
     * scan into another subnet.
     */
    private fun wifiTargets(): List<LanTarget> {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return emptyList()
        @Suppress("DEPRECATION") // allNetworks is the API 26-compatible enumeration.
        val networks = listOfNotNull(connectivity.activeNetwork) + connectivity.allNetworks.toList()
        val seen = HashSet<Long>()
        val targets = ArrayList<LanTarget>()
        for (network in networks) {
            if (!seen.add(network.networkHandle)) continue
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) continue
            val interfaceName = connectivity.getLinkProperties(network)?.interfaceName ?: continue
            if (!interfaceName.startsWith("wlan")) continue
            if (EXCLUDED_INTERFACE_PREFIXES.any { interfaceName.startsWith(it) }) continue
            val iface = try {
                NetworkInterface.getByName(interfaceName)
            } catch (_: IOException) {
                null
            } ?: continue
            if (!iface.isUp) continue
            for (host in subnetHosts(iface)) targets.add(LanTarget(network, host))
        }
        return targets
    }

    /** Usable host addresses (network and broadcast excluded) for one interface. */
    private fun subnetHosts(iface: NetworkInterface): List<String> {
        val hosts = LinkedHashSet<Long>()
        for (address in iface.interfaceAddresses) {
            val ipv4 = address.address as? Inet4Address ?: continue
            if (ipv4.isLoopbackAddress || ipv4.isLinkLocalAddress) continue
            val value = ipv4Value(ipv4)
            val prefix = address.networkPrefixLength.toInt().coerceIn(0, 32)
            val mask = if (prefix == 0) 0L else (0xffffffffL shl (32 - prefix)) and 0xffffffffL
            val network = value and mask
            val broadcast = network or (mask.inv() and 0xffffffffL)
            if (broadcast <= network) continue
            var host = network + 1
            while (host < broadcast && hosts.size < MAX_HOSTS) {
                if (host in 1..0xfffffffeL) hosts.add(host)
                host++
            }
        }
        return hosts.map(::ipv4Text)
    }

    /**
     * Ranks the hosts whose ports answered. A 5555 hit sorts first because that
     * is the endpoint ADB will dial and the only "可控制" evidence this host has;
     * an open media port alone is still shown, as 可能不是电视.
     */
    private fun candidates(openPorts: Map<String, Set<Int>>): List<AndroidAdbCandidate> =
        openPorts.map { (host, ports) ->
            AndroidAdbCandidate(
                id = "$host:$ADB_PORT",
                host = host,
                port = ADB_PORT,
                displayName = "TV · $host",
                kind = kindOf(ports),
                controllable = ADB_PORT in ports,
            )
        }.sortedWith(
            compareByDescending<AndroidAdbCandidate> { it.controllable }
                .thenBy { it.displayName }
                .thenBy { it.host },
        )

    private fun kindOf(ports: Set<Int>): AndroidAdbCandidateKind = when {
        ports.any { it == ADB_PORT || it in XIAOMI_SERVICE_PORTS } -> AndroidAdbCandidateKind.ANDROID_TV
        CAST_PORT in ports -> AndroidAdbCandidateKind.CAST
        AIRPLAY_PORT in ports -> AndroidAdbCandidateKind.AIRPLAY
        ROKU_PORT in ports -> AndroidAdbCandidateKind.ROKU
        ports.any { it in MEDIA_SERVICE_PORTS } -> AndroidAdbCandidateKind.SMART_TV
        else -> AndroidAdbCandidateKind.UNKNOWN
    }

    private fun ipv4Value(address: Inet4Address): Long {
        val bytes = address.address
        if (bytes.size != 4) return 0
        return ((bytes[0].toLong() and 0xff) shl 24) or
            ((bytes[1].toLong() and 0xff) shl 16) or
            ((bytes[2].toLong() and 0xff) shl 8) or
            (bytes[3].toLong() and 0xff)
    }

    private fun ipv4Text(value: Long): String =
        "${(value ushr 24) and 0xff}.${(value ushr 16) and 0xff}.${(value ushr 8) and 0xff}.${value and 0xff}"

    private data class LanTarget(val network: Network, val host: String)

    private data class ProbeJob(val network: Network, val host: String, val port: Int)

    private companion object {
        /** The ADB port the page's 连接 step dials, and the strongest TV evidence. */
        const val ADB_PORT: Int = 5555
        const val CAST_PORT: Int = 8009
        const val AIRPLAY_PORT: Int = 7000
        const val ROKU_PORT: Int = 8060
        val XIAOMI_SERVICE_PORTS: Set<Int> = setOf(6095, 6091)
        val MEDIA_SERVICE_PORTS: Set<Int> = setOf(6466, 6467)
        val PORTS: List<Int> = listOf(5555, 6095, 6091, 8009, 7000, 6466, 6467, 8060)

        const val CONCURRENCY: Int = 64
        const val CONNECT_TIMEOUT_MS: Int = 400
        const val OVERALL_BUDGET_MS: Long = 8_000
        const val MAX_HOSTS: Int = 4_096

        /** Families that must never be treated as the LAN even if a name looked close. */
        val EXCLUDED_INTERFACE_PREFIXES: List<String> =
            listOf("pdp_ip", "rmnet", "ccmni", "tun", "utun", "ppp", "ipsec", "lo")
    }
}
