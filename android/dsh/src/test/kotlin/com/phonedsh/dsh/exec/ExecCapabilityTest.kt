// phone-dsh — :dsh unit test: exec/1 is only claimed with a real tool.
// SPDX-License-Identifier: MIT
//
// channel.md §4.1 makes exec/1 a claim about a working EXEC_REQ → EXEC_EVT path.
// The tests below pin the type-level expression of that claim: an empty tool
// collection has no Available value, contributes no capability string, and the
// bridge cannot be built from it. `ExecCapability.of` demands its first tool as a
// separate parameter, so `ExecCapability.of()` is a compile error in production
// code; the reflection assertion documents that this is not an accident.

package com.phonedsh.dsh.exec

import com.phonedsh.dsh.tools.RegisteredTool
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecCapabilityTest {
    private val tool = CountingTool()

    @Test
    fun zeroToolsCannotClaimExecOne() {
        assertNull("an empty collection is not a ToolSet", ToolSet.from(emptyList()))
        assertEquals(ExecCapability.Unavailable, ExecCapability.from(emptyList()))
        assertTrue(ExecCapability.Unavailable.caps().isEmpty())

        val base = setOf("channel/1", "wal/1")
        val declared = ExecCapability.Unavailable.helloCaps(base)
        assertEquals(base, declared)
        assertFalse("exec/1 without a tool", "exec/1" in declared)
    }

    @Test
    fun availableIsOnlyReachableFromANonEmptyToolSet() {
        // Every constructor — private, or Kotlin's synthetic access bridge —
        // takes a ToolSet, and a ToolSet cannot be empty. There is no
        // `Available(emptyList())` spelling and no no-arg construction.
        val constructors = ExecCapability.Available::class.java.declaredConstructors
        assertTrue(constructors.isNotEmpty())
        assertTrue(
            "every Available constructor must require a (non-empty) ToolSet",
            constructors.all { constructor ->
                constructor.parameterTypes.any { it == ToolSet::class.java }
            },
        )
        assertTrue(
            "no Available constructor may be called without arguments",
            constructors.none { it.parameterCount == 0 },
        )

        // The factory's first parameter is mandatory: of(first, vararg rest).
        val factory = ExecCapability.Companion::class.java.declaredMethods
            .single { it.name == "of" }
        assertEquals(2, factory.parameterCount)
        assertEquals(RegisteredTool::class.java, factory.parameterTypes[0])

        // ExecBridge accepts only Available, so a bridge over Unavailable is
        // unrepresentable as well.
        val bridgeParameter = ExecBridge::class.java.declaredConstructors
            .flatMap { it.parameterTypes.toList() }
            .firstOrNull { it == ExecCapability.Available::class.java }
        assertEquals(ExecCapability.Available::class.java, bridgeParameter)
    }

    @Test
    fun oneExecutableToolTurnsOnExecAndItsAcceleratorName() {
        val capability = ExecCapability.of(RegisteredTool("phone", tool))

        assertEquals(listOf("phone"), capability.names)
        assertEquals(setOf("exec/1", "accelerator:phone"), capability.caps())
        assertEquals(
            setOf("channel/1", "wal/1", "exec/1", "accelerator:phone"),
            capability.helloCaps(setOf("channel/1", "wal/1")),
        )
    }

    @Test
    fun everyAdvertisedToolIsAnAcceleratorFromTheSpec() {
        val capability = ExecCapability.of(
            RegisteredTool("rg", tool),
            RegisteredTool("jaq", tool),
            RegisteredTool("phone", tool),
        )

        assertEquals(listOf("rg", "jaq", "phone"), capability.names)
        assertEquals(
            setOf(
                "exec/1",
                "accelerator:rg",
                "accelerator:jaq",
                "accelerator:phone",
            ),
            capability.caps(),
        )
        // A handler that is not a read-only accelerator cannot be smuggled in.
        assertThrows(IllegalArgumentException::class.java) {
            ExecCapability.of(RegisteredTool("write", tool))
        }
        assertThrows(IllegalArgumentException::class.java) {
            ExecCapability.from(listOf(RegisteredTool("rg", tool), RegisteredTool("bash", tool)))
        }
    }

    @Test
    fun theDynamicFactoryKeepsTheSameInvariant() {
        val capability = ExecCapability.from(listOf(RegisteredTool("rg", tool)))

        assertTrue(capability is ExecCapability.Available)
        assertEquals(setOf("exec/1", "accelerator:rg"), capability.caps())
        assertEquals(ExecCapability.Unavailable, ExecCapability.from(listOf()))
    }
}
