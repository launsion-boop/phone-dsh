// phone-dsh — :dsh unit test: the model-route fact a launch publishes (P27).
// SPDX-License-Identifier: MIT
//
// The pre-fix behaviour these assertions exist against: a launch with no
// `pdsh.deepseek.baseUrl` published the placeholder credential and the key
// state, published no route, and the Worker's pinned `llm-deepseek` resolver
// filled the gap with `PUBLIC_BASE_URL` — real traffic to api.deepseek.com with
// a value that cannot authenticate, and a 401 that blamed the key. Every launch
// shape below is one the composition root can produce; the last test is the
// anchor for the reverse verification (it fails for any implementation that
// answers "no base URL" with a route).

package com.phonedsh.dsh.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelRouteTest {

    private val base = "https://api.deepseek.com/anthropic"

    /** The edge route: endpoint named, proxy requested, a key store installed. */
    @Test
    fun `a launch that can mount an edge publishes host-edge and nothing missing`() {
        val fact = ModelRouteFact.forLaunch(
            baseUrl = base,
            proxyRequested = true,
            credentialAvailable = true,
        )
        assertEquals(ModelRoute.HOST_EDGE, fact.route)
        assertTrue(fact.routable)
        assertNull(fact.missing)
        assertEquals(mapOf("PDSH_MODEL_ROUTE" to "host-edge"), fact.workerEnvironment())
        assertNull("a routable launch says nothing about a failure's cause", fact.diagnosis())
    }

    /**
     * The scripted/diagnostic route: the launch itself asked for no edge.
     *
     * Its Worker env keeps `DEEPSEEK_BASE_URL` (the host's own value), so the
     * route must stay routable and must publish no "missing" member.
     */
    @Test
    fun `a no-edge launch that named a base URL publishes direct`() {
        val fact = ModelRouteFact.forLaunch(
            baseUrl = "http://127.0.0.1:40053",
            proxyRequested = false,
            credentialAvailable = true,
        )
        assertEquals(ModelRoute.DIRECT, fact.route)
        assertTrue(fact.routable)
        assertEquals(mapOf("PDSH_MODEL_ROUTE" to "direct"), fact.workerEnvironment())
        assertNull(fact.diagnosis())
    }

    /**
     * The P27 case: **no base URL**, so no edge, so no route.
     *
     * The published members are the ones the Worker refuses on. The diagnosis
     * names `pdsh.deepseek.baseUrl` and never the key: the key state is a
     * separate fact (P25) and this launch may well have a configured key.
     */
    @Test
    fun `a launch with no base URL publishes none and names the base URL`() {
        val fact = ModelRouteFact.forLaunch(
            baseUrl = null,
            proxyRequested = true,
            credentialAvailable = false,
        )
        assertEquals(ModelRoute.NONE, fact.route)
        assertFalse(fact.routable)
        assertEquals(ModelRouteMissing.BASE_URL, fact.missing)
        assertEquals(
            mapOf(
                "PDSH_MODEL_ROUTE" to "none",
                "PDSH_MODEL_ROUTE_MISSING" to "base-url",
            ),
            fact.workerEnvironment(),
        )
        val diagnosis = fact.diagnosis()!!
        assertTrue(diagnosis, diagnosis.contains("pdsh.deepseek.baseUrl"))
        assertTrue(diagnosis, diagnosis.contains("no request was sent"))
        assertFalse("the diagnosis must not blame the credential", diagnosis.contains("key is invalid"))
        assertFalse("the diagnosis must not blame the credential", diagnosis.contains("no API key"))
    }

    /**
     * A base URL with no installed key store is also no route.
     *
     * This shape used to be worse than the P27 case: the Worker env kept the
     * real base URL, so the placeholder went to the provider over the public
     * internet. The missing input is the key store, not the endpoint, and the
     * two codes stay distinct so the message does not point at the wrong file.
     */
    @Test
    fun `a base URL without a key store publishes none and names the key store`() {
        val fact = ModelRouteFact.forLaunch(
            baseUrl = base,
            proxyRequested = true,
            credentialAvailable = false,
        )
        assertEquals(ModelRoute.NONE, fact.route)
        assertEquals(ModelRouteMissing.API_KEY_STORE, fact.missing)
        assertEquals(
            mapOf(
                "PDSH_MODEL_ROUTE" to "none",
                "PDSH_MODEL_ROUTE_MISSING" to "api-key-store",
            ),
            fact.workerEnvironment(),
        )
        assertTrue(fact.diagnosis()!!.contains("key store"))
    }

    /** Every green route publishes the route member: an omitted member is an ambiguity. */
    @Test
    fun `the route member is always published`() {
        val shapes = listOf(
            Triple(base, true, true),
            Triple(base, false, true),
            Triple(base, false, false),
            Triple(null, true, true),
            Triple(null, false, false),
        )
        for ((baseUrl, proxy, credential) in shapes) {
            val env = ModelRouteFact.forLaunch(baseUrl, proxy, credential).workerEnvironment()
            assertTrue("route member missing for $baseUrl/$proxy/$credential", env.containsKey(ModelRouteFact.ENV))
            assertTrue(env.getValue(ModelRouteFact.ENV) in setOf("host-edge", "direct", "none"))
        }
    }

    /** A fact cannot claim "none" without saying what was missing, nor claim a gap with a route. */
    @Test(expected = IllegalArgumentException::class)
    fun `none must name what was missing`() {
        ModelRouteFact(ModelRoute.NONE)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a routable fact must not name a missing input`() {
        ModelRouteFact(ModelRoute.HOST_EDGE, ModelRouteMissing.BASE_URL)
    }
}
