// SPDX-License-Identifier: MIT
// The embedded `workspace/1` inventory must equal `spec/pclink/v1/endpoints.json`
// row by row, and an unknown endpoint stays forwarded with the `unsafe` class
// (there is no endpoint allowlist; `pclink.admin/` is the one forbidden prefix).
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkEndpointsTest {
    @Test
    fun embeddedTableEqualsTheNormativeFileRowByRow() {
        val document = TestSupport.endpointsDocument()
        PclinkWire.validateEndpointsInventory(document)
        assertEquals(1L, document.requiredLong("v"))
        assertEquals(PclinkEndpoints.SUITE, document.requiredString("suite"))
        assertEquals(PclinkEndpoints.DSH_TESTED_RANGE, document.requiredString("dshTestedRange"))
        assertEquals("unsafe", document.requiredString("defaultRetry"))
        assertEquals(PclinkRetryClass.UNSAFE, PclinkEndpoints.DEFAULT_RETRY)

        val endpoints = TestSupport.objects(document, "endpoints")
        assertEquals(57, endpoints.size)
        assertEquals(57, PclinkEndpoints.inventory.size)

        val names = LinkedHashSet<String>()
        for (entry in endpoints) {
            val name = entry.requiredString("name")
            assertTrue("duplicate endpoint $name", names.add(name))
            val spec = PclinkEndpoints.specFor(name)
                ?: throw AssertionError("embedded inventory is missing $name")
            val kind = PclinkEndpointKind.valueOf(entry.requiredString("kind").uppercase())
            val retry = PclinkRetryClass.valueOf(entry.requiredString("retry").uppercase())
            val phoneOnly = entry.requiredBool("phoneOnly")
            assertEquals("$name kind", kind, spec.kind)
            assertEquals("$name retry", retry, spec.retry)
            assertEquals("$name phoneOnly", phoneOnly, spec.phoneOnly)
            assertEquals("$name retryClass", retry, PclinkEndpoints.retryClass(name))
            // Every stream endpoint in the inventory is `read` (§7): a stream
            // cannot be blindly resent.
            if (kind == PclinkEndpointKind.STREAM) {
                assertEquals("$name stream retry", PclinkRetryClass.READ, retry)
            }
            // The `phone/*` namespace is the only phone-only one.
            assertEquals("$name phone namespace", name.startsWith("phone/"), phoneOnly)
        }
        assertEquals(names, PclinkEndpoints.inventory.keys)
    }

    @Test
    fun unknownEndpointIsUnsafeAndStillForwarded() {
        val unknown = "workspace/notInTheInventory"
        assertNull(PclinkEndpoints.specFor(unknown))
        assertEquals(PclinkRetryClass.UNSAFE, PclinkEndpoints.retryClass(unknown))
        // No allowlist: only the pclink.admin/ prefix is forbidden.
        assertTrue(PclinkValidation.isEndpoint(unknown))
        assertFalse(PclinkEndpoints.isForbiddenRemoteAdmin(unknown))
        assertFalse(PclinkEndpoints.isForbiddenRemoteAdmin("session/list"))
        assertFalse(PclinkEndpoints.isForbiddenRemoteAdmin("pclink.adminx/status"))
        assertTrue(PclinkEndpoints.isForbiddenRemoteAdmin("pclink.admin/status"))
        // The forwarder's prefix test is a fast path; the endpoint shape itself
        // still accepts the admin string so the refusal is the PCLink code.
        assertTrue(PclinkValidation.isEndpoint("pclink.admin/status"))
    }
}
