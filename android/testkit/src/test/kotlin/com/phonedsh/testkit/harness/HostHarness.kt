// :testkit harness tests — the machine setup the third runner needs on a JVM.
// SPDX-License-Identifier: MIT
//
// The host VFS/WAL path is not pure JVM: `WorkspaceLog.recover()` and
// `VfsSink` decode/encode through `libpdsh_jni` (the Rust `pdsh-wire`/`pdsh-wal`
// kernel). That library is a host build (`cd shell && cargo build -p pdsh-jni`),
// and `:testkit`'s test task does not put `shell/target/debug` on
// `java.library.path` (its build file is out of this lane's write scope). The
// JVM's default `java.library.path` does contain `.`, and Gradle runs the test
// worker with the project directory as its working directory, so the one
// machine-local step this support does is copy the built library next to the
// worker. It is a staged build artifact, not a source file, and the copy is
// skipped when it is already there.

package com.phonedsh.testkit.harness

import com.phonedsh.testkit.scenario.CatalogLoader
import com.phonedsh.testkit.scenario.ScenarioCatalog
import com.phonedsh.wire.NativeWire
import java.io.File

internal object HostHarness {
    /** The repository root, provided by `:testkit/build.gradle.kts` (`pdsh.repo.root`). */
    val repoRoot: File = File(
        System.getProperty("pdsh.repo.root")
            ?: throw IllegalStateException(
                "pdsh.repo.root is not set; :testkit/build.gradle.kts must provide it",
            ),
    )

    /** The checked-in 56-scenario catalog, the same document the macOS runner reads. */
    val catalog: ScenarioCatalog by lazy {
        CatalogLoader.load(File(repoRoot, "scripts/ci/scenarios/catalog.json"))
    }

    /** `scripts/ci/scenarios/fixtures`, the payload root the runner copies from. */
    val fixtureRoot: File = File(repoRoot, "scripts/ci/scenarios/fixtures")

    /**
     * Makes `libpdsh_jni` loadable in this JVM, or fails with the build command.
     *
     * Call it before the first `WireCodec`/`WorkspaceLog` use in a test class
     * (a `@Before` method is early enough).
     */
    fun stageNativeCodec() {
        // Stage before the first `NativeWire` touch: that object's initializer
        // calls `System.loadLibrary` exactly once and caches the failure, so a
        // copy made after an availability check would be too late.
        val built = File(repoRoot, "shell/target/debug/" + System.mapLibraryName("pdsh_jni"))
        val staged = File("").absoluteFile.resolve(System.mapLibraryName("pdsh_jni"))
        if (built.isFile && (!staged.isFile || staged.length() != built.length())) {
            built.copyTo(staged, overwrite = true)
            removeOnExit(staged)
        }
        check(NativeWire.available) {
            "the Rust wire/WAL codec is not loadable (${NativeWire.failure}); build it with " +
                "`cd shell && cargo build -p pdsh-jni`"
        }
    }

    /**
     * Removes a copy this JVM staged once the JVM exits, so no native binary is
     * left in the module directory after a test run. The library is already
     * mapped by then, so deleting the file does not unload it.
     */
    private fun removeOnExit(staged: File) {
        if (!removeOnExitRegistered) {
            removeOnExitRegistered = true
            Runtime.getRuntime().addShutdownHook(
                Thread {
                    staged.delete()
                }.apply { name = "pdsh-testkit-native-cleanup" },
            )
        }
    }

    private var removeOnExitRegistered: Boolean = false

    /** One fixture payload file, byte for byte, for the anti-fabrication checks. */
    fun fixtureBytes(fixture: String, path: String): ByteArray =
        File(File(File(fixtureRoot, fixture), "files"), path).readBytes()
}
