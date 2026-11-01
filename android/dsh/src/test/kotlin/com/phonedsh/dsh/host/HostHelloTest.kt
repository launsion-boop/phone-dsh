// phone-dsh — :dsh unit test: the host HELLO value and its capability vocabulary.
// SPDX-License-Identifier: MIT
//
// The encoding path is asserted end-to-end in PhoneDshHostTest (encode through
// the Rust codec, decode back). This file pins the *value* rules that must hold
// regardless of the codec: every §4.1 host member is present, `boot_id` has the
// D6 shape, a capability the host does not have cannot be invented, and a
// watermark without a log says so instead of looking empty but valid.

package com.phonedsh.dsh.host

import com.phonedsh.dsh.exec.ExecCapability
import com.phonedsh.dsh.tools.RegisteredTool
import com.phonedsh.wire.WireCodec
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class HostHelloTest {
    @Test
    fun theFieldsCarryEveryMemberTheHostVariantRequires() {
        val hello = hello()
        val fields = JSONObject(hello.fieldsJson())

        // channel.md §4.1: host = yes for each of these; last_mseq is worker-only.
        for (member in listOf(
            "proto",
            "role",
            "boot_id",
            "session_epoch",
            "fence",
            "caps",
            "next_mseq",
            "acked_mseq",
            "durable_mseq",
        )) {
            assertTrue("missing HELLO member $member", fields.has(member))
        }
        assertFalse("last_mseq is worker-only", fields.has("last_mseq"))
        assertEquals(1, fields.getInt("proto"))
        assertEquals("host", fields.getString("role"))
        assertEquals(7L, fields.getLong("session_epoch"))
        assertTrue(BootId.isValid(fields.getString("boot_id")))
    }

    @Test
    fun theFrameJSONRoundTripsThroughTheRustCodec() {
        val hello = hello()
        val decoded = JSONObject(WireCodec.decode(hello.encode()))

        // Member order in JSONObject is not a contract; canonical JSON is (§5).
        assertEquals(
            WireCodec.canonicalJson(hello.fieldsJson()),
            WireCodec.canonicalJson(decoded.toString()),
        )
        assertEquals(hello.bootId, decoded.getString("boot_id"))
        assertEquals(hello.watermark.nextMseq, decoded.getLong("next_mseq"))
    }

    @Test
    fun onlyDefinedCapabilitiesAreAccepted() {
        // §4.1: "Other capability strings are reserved". A typo must fail at the
        // seam instead of becoming a capability the worker trusts.
        for (bad in listOf("wal/2", "exec/1 ", "accelerator:grep", "channel", "")) {
            try {
                HostCapabilities(setOf(HostCapabilities.CHANNEL, bad))
                fail("capability \"$bad\" should have been refused")
            } catch (expected: IllegalArgumentException) {
                // expected
            }
        }
        try {
            HostCapabilities(setOf(HostCapabilities.WAL))
            fail("a host HELLO without channel/1 should have been refused")
        } catch (expected: IllegalArgumentException) {
            // expected
        }
        try {
            HostCapabilities(emptySet())
            fail("a host HELLO with no capabilities should have been refused")
        } catch (expected: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun theCurrentCapabilitySetIsOnlyTheChannel() {
        assertEquals(listOf("channel/1"), HostCapabilities.CURRENT.toHelloList())
        assertEquals("[channel/1]", HostCapabilities.CURRENT.describe())
    }

    @Test
    fun aWiringCanAdvertiseMoreOnceTheLaneExists() {
        // The seam the WAL/exec lanes use: the same host, one constructor argument.
        val richer = HostCapabilities(
            setOf(
                HostCapabilities.CHANNEL,
                HostCapabilities.WAL,
                HostCapabilities.EXEC,
                "accelerator:rg",
            ),
        )
        assertEquals(listOf("channel/1", "wal/1", "exec/1", "accelerator:rg"), richer.toHelloList())
    }

    @Test
    fun aNotWiredWatermarkIsZeroAndDoesNotPretendToBeValid() {
        val notWired = MseqWatermark.NotWired
        assertEquals(0L, notWired.nextMseq)
        assertEquals(0L, notWired.ackedMseq)
        assertEquals(0L, notWired.durableMseq)
        assertFalse(notWired.satisfiesHelloRules)
        assertTrue(notWired.provenance.contains("not-wired"))

        // `Down` is the only way a HELLO carries NotWired, and it never carries
        // wal/1 with it.
        val down = hello(wal = WalUplink.down("test: no WAL attached"))
        val fields = JSONObject(down.fieldsJson())
        assertEquals(0L, fields.getLong("next_mseq"))
        assertEquals(0L, fields.getLong("acked_mseq"))
        assertEquals(0L, fields.getLong("durable_mseq"))
        assertFalse(capsOf(fields).contains(HostCapabilities.WAL))
        assertEquals(MseqWatermark.NotWired, down.watermark)
        assertEquals(HostCapabilities.CURRENT, down.capabilities)
    }

    @Test
    fun theEmptyLogWatermarkAppliesTheD17Formula() {
        val empty = MseqWatermark.EmptyLog
        assertEquals(1L, empty.nextMseq)
        assertEquals(0L, empty.ackedMseq)
        assertEquals(0L, empty.durableMseq)
        assertTrue(empty.satisfiesHelloRules)
        assertTrue(empty.provenance.contains("empty-log"))
    }

    @Test
    fun walOneCannotBePairedWithAnIllegalWatermark() {
        // `WalUplink.up` takes an Observed and re-checks §4.1, so the bad
        // capability/watermark pair has no spelling: this is the construction
        // guard behind the compile-time shape of HostHello.
        val broken = MseqWatermark.Observed(nextMseq = 40, ackedMseq = 41, durableMseq = 42)
        assertFalse(broken.satisfiesHelloRules)
        try {
            WalUplink.up(broken, wiredProof())
            fail("wal/1 must not be paired with a watermark that breaks §4.1")
        } catch (expected: IllegalArgumentException) {
            // expected
        }

        // The legal value is carried verbatim, not "fixed".
        val legal = hello(wal = wiredUplink(42, 41, 40))
        val fields = JSONObject(legal.fieldsJson())
        assertEquals(42L, fields.getLong("next_mseq"))
        assertEquals(41L, fields.getLong("acked_mseq"))
        assertEquals(40L, fields.getLong("durable_mseq"))
        assertTrue(capsOf(fields).contains(HostCapabilities.WAL))
    }

    @Test
    fun walOneRequiresTheVfsSinkProof() {
        // Compile-level gate: `WalUplink.up` has one overload and it takes the
        // sink's Wired proof; `Wired`'s constructor is private. Code outside
        // :dsh cannot construct either, so it cannot advertise wal/1 before the
        // VFS sink exists.
        val upMethods = WalUplink.Companion::class.java.declaredMethods.filter { it.name == "up" }
        assertEquals("exactly one up() overload", 1, upMethods.size)
        assertTrue(
            "up() must require VfsSink.Wired",
            upMethods.single().parameterTypes.contains(VfsSink.Wired::class.java),
        )
        val wiredConstructors = VfsSink.Wired::class.java.declaredConstructors
        assertTrue("Wired has a constructor", wiredConstructors.isNotEmpty())
        // Kotlin emits a public synthetic `Wired(DefaultConstructorMarker)`
        // bridge for a private constructor; the source-level constructor is the
        // non-synthetic one and it is private. Kotlin callers outside :dsh see
        // neither.
        val sourceConstructors = wiredConstructors.filterNot { it.isSynthetic }
        assertTrue("Wired has a source-level constructor", sourceConstructors.isNotEmpty())
        assertTrue(
            "every source-level Wired constructor is private",
            sourceConstructors.all { java.lang.reflect.Modifier.isPrivate(it.modifiers) },
        )
    }

    @Test
    fun theFenceOwnerIsValidatedAgainstTheSpecSyntax() {
        for (bad in listOf("", "has space", "quote\"d", "a".repeat(65))) {
            try {
                HostFence(owner = bad, generation = 0, walSeq = 0)
                fail("fence owner \"$bad\" should have been refused")
            } catch (expected: IllegalArgumentException) {
                // expected
            }
        }
        assertEquals("phone", HostFence.LOCAL.owner)
        assertEquals(0L, HostFence.LOCAL.generation)
    }

    @Test
    fun theExecCapabilityMergesIntoCapsWithoutTouchingTheWatermark() {
        val exec = ExecCapability.of(
            RegisteredTool(
                "phone",
                PhoneInfoTool(PhoneInfoSource { """{"model":"test-device","sdk":35}""" }),
            ),
        )
        val value = hello(exec = exec)
        assertEquals(
            listOf(
                HostCapabilities.CHANNEL,
                HostCapabilities.WAL,
                HostCapabilities.EXEC,
                "accelerator:phone",
            ),
            value.caps,
        )
        // The watermark still comes only from the WAL lane.
        assertEquals(42L, value.watermark.nextMseq)
        assertEquals(41L, value.watermark.ackedMseq)
        assertEquals(40L, value.watermark.durableMseq)
    }

    @Test
    fun anUnavailableExecCapabilityAddsNothing() {
        val value = hello()
        assertEquals(listOf(HostCapabilities.CHANNEL, HostCapabilities.WAL), value.caps)
        assertFalse(value.caps.contains(HostCapabilities.EXEC))
    }

    private fun hello(
        wal: WalUplink = wiredUplink(),
        exec: ExecCapability = ExecCapability.Unavailable,
    ): HostHello = HostHello(
        bootId = BootId.generate(),
        sessionEpoch = 7,
        fence = HostFence.LOCAL,
        wal = wal,
        exec = exec,
    )

    private fun capsOf(fields: JSONObject): List<String> {
        val array = fields.getJSONArray("caps")
        return (0 until array.length()).map { array.getString(it) }
    }
}
