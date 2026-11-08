// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.SystemClock
import com.phonedsh.domain.connector.lan.DnsMessageParser
import com.phonedsh.domain.connector.lan.DnsParseResult
import com.phonedsh.domain.connector.lan.LanMdnsBrowser
import com.phonedsh.ui.nav.PdshHostAction
import com.phonedsh.ui.page.LanCandidateFact
import com.phonedsh.ui.page.LanDiscoveryFacts
import com.phonedsh.ui.page.LanScanStatus
import java.io.IOException
import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * LAN MCP device discovery (`spec/device/v1/lan-mcp.md`) over the Wi-Fi interface.
 *
 * Android's `NsdManager` cannot be used: it hands TXT over as a `Map` (duplicate
 * keys collapse, so a repeated `profile` cannot be refused) and resolves to an
 * `InetAddress` instead of the SRV target hostname that TLS must validate. This
 * class therefore owns a minimal, read-only mDNS querier; every byte it receives
 * goes through the strict, bounded `DnsMessageParser` and `LanMdnsBrowser` in
 * `:domain`, which feed `LanDiscoveryDecoder`.
 *
 * Scope and bounds (all hard):
 *  * a scan only runs after the person taps 扫描局域网设备 and stops after
 *    [SCAN_MS] or on 停止扫描 / leaving the page; results are cleared [EXPIRY_MS]
 *    after the scan started (both match the iOS `LANDeviceDiscovery`);
 *  * IPv4 only, on the Wi-Fi network's interface, with a `MulticastLock` held for
 *    the scan alone;
 *  * a datagram counts only when it came from UDP 5353 and an on-link IPv4 source
 *    (RFC 6762 §11); larger than 9000 bytes is refused before parsing;
 *  * at most [MAX_DATAGRAMS] datagrams are read per scan and [MAX_RESOLVE_QUERIES]
 *    follow-up SRV/TXT queries are sent;
 *  * nothing connects to a candidate, stores it or grants it.
 *
 * If UDP 5353 cannot be shared, the querier falls back to an ephemeral port: per
 * RFC 6762 §6.7 responders then answer by unicast to that port (legacy unicast),
 * which still carries complete PTR/SRV/TXT answers.
 */
internal class AndroidLanDiscovery(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutable = MutableStateFlow(LanDiscoveryFacts(status = LanScanStatus.IDLE))
    val facts: StateFlow<LanDiscoveryFacts> = mutable.asStateFlow()

    /** Bumped per start/stop so a finished or cancelled scan cannot publish over a newer one. */
    private val generation = AtomicInteger()
    private var scanJob: Job? = null
    private var expiryJob: Job? = null
    @Volatile private var socket: MulticastSocket? = null

    fun handle(action: PdshHostAction) {
        when (action) {
            is PdshHostAction.LanScan -> if (action.start) start() else stop()
            else -> return
        }
    }

    private fun start() {
        if (mutable.value.scanning) return
        val gen = generation.incrementAndGet()
        expiryJob?.cancel()
        mutable.value = LanDiscoveryFacts(status = LanScanStatus.SCANNING, scanning = true)
        scanJob = scope.launch(Dispatchers.IO) { scan(gen) }
        // Cancelled by the next start, so it only ever clears this scan's results.
        expiryJob = scope.launch {
            delay(EXPIRY_MS)
            if (!mutable.value.scanning) mutable.value = LanDiscoveryFacts(status = LanScanStatus.EXPIRED)
        }
    }

    private fun stop() {
        if (!mutable.value.scanning) return
        generation.incrementAndGet()
        scanJob?.cancel()
        scanJob = null
        socket?.close()
        val current = mutable.value
        mutable.value = current.copy(
            scanning = false,
            status = if (current.candidates.isEmpty()) LanScanStatus.NONE_FOUND else LanScanStatus.FOUND,
        )
    }

    private fun publish(gen: Int, update: (LanDiscoveryFacts) -> LanDiscoveryFacts) {
        // A compare-and-set loop, abandoned as soon as a newer start/stop owns the facts.
        while (generation.get() == gen) {
            val old = mutable.value
            if (mutable.compareAndSet(old, update(old))) return
        }
    }

    private suspend fun scan(gen: Int) {
        val wifi = wifiNetwork()
        if (wifi == null) {
            publish(gen) { LanDiscoveryFacts(status = LanScanStatus.NO_WIFI) }
            return
        }
        val (network, iface) = wifi
        val subnets = iface.interfaceAddresses
            .filter { it.address is Inet4Address }
            .map { it.address.address to it.networkPrefixLength.toInt() }
        if (subnets.isEmpty()) {
            publish(gen) { LanDiscoveryFacts(status = LanScanStatus.NO_WIFI) }
            return
        }
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifiManager.createMulticastLock("pdsh-lan-mcp").apply { setReferenceCounted(false) }
        var failed = false
        var opened: MulticastSocket? = null
        try {
            lock.acquire()
            val (bound, legacyUnicast) = open(network, iface)
            opened = bound
            socket = bound
            // A stop() that raced the open could not close this socket yet.
            if (generation.get() != gen) return
            browse(gen, bound, legacyUnicast, subnets)
        } catch (_: IOException) {
            failed = true
        } catch (_: SecurityException) {
            failed = true
        } finally {
            opened?.close()
            if (socket === opened) socket = null
            if (lock.isHeld) lock.release()
        }
        publish(gen) { current ->
            current.copy(
                scanning = false,
                status = when {
                    failed && current.candidates.isEmpty() -> LanScanStatus.FAILED
                    current.candidates.isEmpty() -> LanScanStatus.NONE_FOUND
                    else -> LanScanStatus.FOUND
                },
            )
        }
    }

    private suspend fun browse(gen: Int, socket: MulticastSocket, legacyUnicast: Boolean, subnets: List<Pair<ByteArray, Int>>) {
        val browser = LanMdnsBrowser()
        val group = InetSocketAddress(InetAddress.getByAddress(LanMdnsBrowser.MDNS_IPV4_GROUP), LanMdnsBrowser.MDNS_PORT)
        val queryId = if (legacyUnicast) (SystemClock.elapsedRealtime().toInt() and 0xffff) or 1 else 0
        val buffer = ByteArray(DnsMessageParser.MAX_MESSAGE_BYTES + 1)
        val started = SystemClock.elapsedRealtime()
        val browseAt = BROWSE_SCHEDULE_MS.toMutableList()
        val resolved = HashMap<String, Long>()
        var resolveQueries = 0
        var datagrams = 0
        socket.soTimeout = RECEIVE_SLICE_MS
        while (coroutineContextActive() && generation.get() == gen) {
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - started
            if (elapsed >= SCAN_MS || datagrams >= MAX_DATAGRAMS) return
            if (browseAt.isNotEmpty() && elapsed >= browseAt.first()) {
                browseAt.removeAt(0)
                send(socket, LanMdnsBrowser.browseQuery(queryId), group)
            }
            for (name in browser.unresolved(now)) {
                val key = name.key
                val last = resolved[key]
                if (resolveQueries >= MAX_RESOLVE_QUERIES || (last != null && now - last < RESOLVE_INTERVAL_MS)) continue
                resolved[key] = now
                resolveQueries++
                send(socket, LanMdnsBrowser.resolveQuery(name, queryId), group)
            }
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                socket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            }
            datagrams++
            if (packet.length > DnsMessageParser.MAX_MESSAGE_BYTES) continue
            val source = packet.address?.address ?: continue
            if (!LanMdnsBrowser.acceptsSource(source, packet.port, subnets)) continue
            val message = (DnsMessageParser.parse(buffer, packet.length) as? DnsParseResult.Ok)?.message ?: continue
            // A legacy-unicast answer echoes our query ID (RFC 6762 §6.7).
            if (legacyUnicast && message.id != queryId) continue
            val received = SystemClock.elapsedRealtime()
            if (!browser.accept(message, received)) continue
            val candidates = browser.candidates(received).map { LanCandidateFact(it.id, it.name, it.url) }
            publish(gen) { it.copy(candidates = candidates) }
        }
    }

    private suspend fun coroutineContextActive(): Boolean = currentCoroutineContext().isActive

    private fun send(socket: MulticastSocket, bytes: ByteArray, group: InetSocketAddress) {
        try {
            socket.send(DatagramPacket(bytes, bytes.size, group))
        } catch (_: IOException) {
            // A lost query only means fewer answers; the scan deadline still ends it.
        }
    }

    /** Port 5353 shared with the system responder when possible, else an ephemeral port. */
    private fun open(network: Network, iface: NetworkInterface): Pair<MulticastSocket, Boolean> {
        val shared = MulticastSocket(null as java.net.SocketAddress?)
        try {
            shared.reuseAddress = true
            shared.bind(InetSocketAddress(LanMdnsBrowser.MDNS_PORT))
            configure(shared, network, iface)
            shared.joinGroup(
                InetSocketAddress(InetAddress.getByAddress(LanMdnsBrowser.MDNS_IPV4_GROUP), 0),
                iface,
            )
            return shared to false
        } catch (_: IOException) {
            // Includes BindException: 5353 is not shareable here; use legacy unicast.
            shared.close()
        }
        val ephemeral = MulticastSocket(0)
        try {
            configure(ephemeral, network, iface)
        } catch (error: IOException) {
            ephemeral.close()
            throw error
        }
        return ephemeral to true
    }

    private fun configure(socket: MulticastSocket, network: Network, iface: NetworkInterface) {
        network.bindSocket(socket)
        socket.networkInterface = iface
        socket.timeToLive = 255
    }

    /** The Wi-Fi network and its interface; `null` when the phone is not on Wi-Fi. */
    private fun wifiNetwork(): Pair<Network, NetworkInterface>? {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
        @Suppress("DEPRECATION") // allNetworks is the API 26-compatible enumeration.
        val candidates = listOfNotNull(connectivity.activeNetwork) + connectivity.allNetworks.toList()
        for (network in candidates.distinct()) {
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val name = connectivity.getLinkProperties(network)?.interfaceName ?: continue
            val iface = try {
                NetworkInterface.getByName(name)
            } catch (_: IOException) {
                null
            } ?: continue
            if (iface.isUp && iface.supportsMulticast()) return network to iface
        }
        return null
    }

    companion object {
        const val SCAN_MS: Long = 15_000
        const val EXPIRY_MS: Long = 120_000
        const val MAX_DATAGRAMS: Int = 4_096
        const val MAX_RESOLVE_QUERIES: Int = 64
        const val RESOLVE_INTERVAL_MS: Long = 1_000
        const val RECEIVE_SLICE_MS: Int = 200

        /** RFC 6762 §5.2: repeat the browse with increasing intervals. */
        val BROWSE_SCHEDULE_MS: List<Long> = listOf(0, 1_000, 3_000, 7_000)

        @Volatile private var instance: AndroidLanDiscovery? = null
        fun get(context: Context): AndroidLanDiscovery =
            instance ?: synchronized(this) { instance ?: AndroidLanDiscovery(context.applicationContext).also { instance = it } }
    }
}
