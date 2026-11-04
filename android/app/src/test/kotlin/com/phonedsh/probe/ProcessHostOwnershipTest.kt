// The P02 single-writer guard: one host/WAL composition per process.
// SPDX-License-Identifier: MIT
//
// The 2026-11-03 emulator evidence (pr14-handover-20261103/emulator-e2e-42b1ffe7)
// shows two `host boot` lines with different boot_ids in one process: a second
// MainActivity obtained its own `ProbeEngineViewModel`, which constructed a
// second `DefaultPhoneDshHost` and a second `WorkspaceLog` over the same
// `files/xl` WAL directory. wal.md §1 has one writer per workspace, so that is
// the P02 failure this test battery pins:
//
//   1. the ownership primitive used by the App creates one instance even under
//      concurrent first callers and releases only the instance it owns;
//   2. MainActivity obtains its view model through that process-wide factory,
//      not through an Activity-scoped ViewModelStore;
//   3. the view-model companion is the factory's only caller, so no second
//      `WorkspaceLog` can be constructed by the App.
package com.phonedsh.probe

import java.lang.reflect.Modifier
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessHostOwnershipTest {

    @Test
    fun concurrentFirstCallersConstructExactlyOneWriter() {
        val singleton = ProcessSingleton<Writer>()
        val constructions = AtomicInteger(0)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(CALLERS)
        try {
            val tasks = (1..CALLERS).map {
                pool.submit<Writer> {
                    start.await()
                    singleton.obtain {
                        constructions.incrementAndGet()
                        Writer()
                    }
                }
            }
            start.countDown()
            val values = tasks.map { it.get(5, TimeUnit.SECONDS) }

            assertEquals("the factory ran more than once", 1, constructions.get())
            val first = values.first()
            assertTrue(
                "two callers obtained different writers: ${values.map { System.identityHashCode(it) }}",
                values.all { it === first },
            )
            assertSame(first, singleton.peek())
        } finally {
            pool.shutdownNow()
        }
    }

    @Test
    fun clearReleasesOnlyTheInstanceItOwns() {
        val singleton = ProcessSingleton<Writer>()
        val first = singleton.obtain { Writer() }

        // A stale owner must not clear a newer instance.
        val second = Writer()
        singleton.clear(second)
        assertSame("a foreign clear released the owned writer", first, singleton.peek())

        singleton.clear(first)
        assertNull("clear did not release the owned writer", singleton.peek())
        val replacement = singleton.obtain { Writer() }
        assertTrue("the released writer was handed out again", replacement !== first)
    }

    @Test
    fun theViewModelHasNoSecondConstructionPath() {
        val viewModel = Class.forName(
            "com.phonedsh.probe.ProbeEngineViewModel",
            false,
            javaClass.classLoader,
        )
        val constructor = viewModel.declaredConstructors.single {
            it.parameterTypes.size == 1 &&
                it.parameterTypes[0].name == "android.app.Application"
        }
        assertTrue(
            "ProbeEngineViewModel's constructor is not private: any caller can build a " +
                "second composition (and therefore a second WorkspaceLog writer) without " +
                "going through sharedHost",
            Modifier.isPrivate(constructor.modifiers),
        )
    }

    @Test
    fun mainActivityObtainsTheProcessHostNotAnActivityScopedViewModel() {
        val activity = classFile("com/phonedsh/probe/MainActivity.class")
        assertTrue(
            "MainActivity no longer calls ProbeEngineViewModel.sharedHost: the Activity " +
                "may have gone back to an Activity-scoped view model, which is the P02 " +
                "two-writer shape",
            activity.contains("sharedHost"),
        )
        assertFalse(
            "MainActivity still references viewModels(): an Activity-scoped view model " +
                "creates a second host/WAL writer while the previous Activity is alive",
            activity.contains("viewModels"),
        )

        val companion = classFile("com/phonedsh/probe/ProbeEngineViewModel\$Companion.class")
        assertTrue(
            "the view-model companion no longer exposes sharedHost",
            companion.contains("sharedHost"),
        )
        assertTrue(
            "the view-model companion no longer owns a ProcessSingleton",
            companion.contains("ProcessSingleton"),
        )
    }

    /** A stand-in for the one WorkspaceLog writer a composition owns. */
    private class Writer

    private fun classFile(path: String): String {
        val stream = javaClass.classLoader?.getResourceAsStream(path)
            ?: throw AssertionError("$path is not on the test classpath")
        return stream.use { bytes -> String(bytes.readBytes(), Charsets.ISO_8859_1) }
    }

    private companion object {
        const val CALLERS = 8
    }
}
