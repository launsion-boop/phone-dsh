// SPDX-License-Identifier: MIT
// In-memory C2 relay seam. C3 owns the real WebSocket/Ktor link; these tests
// only need frame delivery and close observation.
package com.phonedsh.pclink

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow

interface FakePcServer {
    suspend fun onConnect(link: FakeRelayLink)
    suspend fun onFrame(link: FakeRelayLink, frame: PclinkJson)
}

class FakeRelayLink(private val server: FakePcServer) : PclinkRelayLink {
    private val inbox = Channel<PclinkJson>(Channel.UNLIMITED)
    private val received = CopyOnWriteArrayList<PclinkJson>()

    override val incoming: Flow<PclinkJson> = inbox.receiveAsFlow()

    @Volatile
    var closed: Boolean = false
        private set

    @Volatile
    var closeCode: Int? = null
        private set

    @Volatile
    var closeReason: String? = null
        private set

    val sent: List<PclinkJson> get() = received.toList()

    override suspend fun send(frame: PclinkJson) {
        received.add(frame)
        server.onFrame(this, frame)
    }

    suspend fun deliver(frame: PclinkJson) {
        inbox.send(frame)
    }

    override suspend fun close(code: Int, reason: String) {
        if (closed) return
        closed = true
        closeCode = code
        closeReason = reason
        inbox.close()
    }
}

class FakeRelayFactory(private val server: FakePcServer) : PclinkRelayLinkFactory {
    private val dials = AtomicInteger()
    private val links = CopyOnWriteArrayList<FakeRelayLink>()
    private val urls = CopyOnWriteArrayList<String>()

    val dialCount: Int get() = dials.get()
    val connected: List<FakeRelayLink> get() = links.toList()
    val dialedUrls: List<String> get() = urls.toList()

    override suspend fun connect(url: String): PclinkRelayLink {
        dials.incrementAndGet()
        urls.add(url)
        val link = FakeRelayLink(server)
        links.add(link)
        server.onConnect(link)
        return link
    }
}
