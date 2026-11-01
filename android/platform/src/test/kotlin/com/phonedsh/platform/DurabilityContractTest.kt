// The atomicReplace contract: old bytes or new bytes, never a half file.
// SPDX-License-Identifier: MIT
//
// These tests use FakePlatform.tempDir and a real java.nio implementation
// (LocalDurability), so they exercise the same ordering the Android backend
// must provide instead of asserting on a mock.

package com.phonedsh.platform

import com.phonedsh.platform.testing.FakePlatform
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DurabilityContractTest {
    private lateinit var fake: FakePlatform
    private lateinit var root: Path
    private lateinit var durability: LocalDurability

    @Before
    fun setUp() {
        fake = FakePlatform()
        root = fake.tempDir
        durability = LocalDurability()
    }

    @After
    fun tearDown() {
        fake.close()
    }

    @Test
    fun anInterruptedWriteKeepsTheOldTargetAndLeavesNoHalfFile() = runBlocking {
        val target = root.resolve("manifest.bin")
        Files.writeString(target, "old-bytes")

        var interrupted = false
        try {
            durability.atomicReplace(target) { temp ->
                Files.writeString(temp, "new-but-partial")
                throw IOException("simulated power loss")
            }
        } catch (expected: IOException) {
            interrupted = true
        }

        assertTrue("the injected failure must propagate", interrupted)
        assertEquals("old-bytes", Files.readString(target))
        assertEquals(listOf("manifest.bin"), childNames(root))
    }

    @Test
    fun aSuccessfulReplacePublishesExactlyTheNewBytes() = runBlocking {
        val target = root.resolve("manifest.bin")
        Files.writeString(target, "old")

        durability.atomicReplace(target) { temp ->
            Files.writeString(temp, "new")
        }

        assertEquals("new", Files.readString(target))
        assertEquals(listOf("manifest.bin"), childNames(root))
    }

    @Test
    fun fsyncAcceptsBothRegularFilesAndDirectories() = runBlocking {
        val file = root.resolve("wal.segment")
        Files.writeString(file, "record")

        durability.fsyncPath(file)
        durability.fsyncPath(root)
    }

    @Test
    fun concurrentReadersOnlySeeTheCompleteOldOrCompleteNewFile() = runBlocking {
        val target = root.resolve("manifest.bin")
        val old = "old-".repeat(512)
        val fresh = "new-".repeat(512)
        Files.writeString(target, old)

        val observed = Collections.synchronizedSet(mutableSetOf<String>())
        val failure = AtomicReference<Throwable?>(null)
        val running = AtomicBoolean(true)
        val reader = Thread {
            while (running.get()) {
                try {
                    observed.add(Files.readString(target))
                } catch (problem: Throwable) {
                    failure.compareAndSet(null, problem)
                    running.set(false)
                }
            }
        }
        reader.start()
        try {
            repeat(50) {
                durability.atomicReplace(target) { temp ->
                    Files.writeString(temp, fresh)
                }
            }
        } finally {
            running.set(false)
            reader.join(5_000L)
        }

        assertNull("a reader failed during replacement: ${failure.get()}", failure.get())
        assertTrue("the reader observed nothing", observed.isNotEmpty())
        val torn = observed.filter { it != old && it != fresh }
        assertTrue("a reader observed a torn file: $torn", torn.isEmpty())
    }

    private fun childNames(directory: Path): List<String> =
        Files.newDirectoryStream(directory).use { entries ->
            entries.map { it.fileName.toString() }.sorted()
        }
}
