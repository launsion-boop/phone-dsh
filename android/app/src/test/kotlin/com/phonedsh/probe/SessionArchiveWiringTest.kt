// The CI guard for the persistence wiring L65 added by hand.
// SPDX-License-Identifier: MIT
//
// L65 connected `SessionArchive` (the `:domain` transcript cache) to
// `ProbeEngineViewModel` in about ten lines — a field, a restore launch and a save
// after a completed turn — and the only evidence was a device run. A refactor
// that deletes one of those call sites compiles, leaves the UI unchanged, and
// silently brings back "every cold start forgets the last turn".
//
// This test reads the **compiled** `ProbeEngineViewModel.class` and asserts the
// wiring is in the bytecode: the field's type, the constructor call, the three
// `SessionArchive` methods the restore and save paths use, and the two private
// methods those paths live in. A source-level grep would pass on a commented-out
// line; a constant-pool read cannot.
//
// It also asserts the module edge the design depends on: `:app` links `:domain`
// (it is the composition root that picks a backend) and `:dsh` must not (a
// library that chose a backend would take the decision away from every app that
// links it). The build files are the only place that edge exists.
package com.phonedsh.probe

import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionArchiveWiringTest {

    @Test
    fun probeEngineViewModelConstructsTheSessionArchive() {
        val refs = classRefs("com/phonedsh/probe/ProbeEngineViewModel.class")

        assertTrue(
            "ProbeEngineViewModel no longer declares a SessionArchive field: the " +
                "transcript cache is not wired into the view model any more",
            SESSION_ARCHIVE_DESCRIPTOR in refs.fieldDescriptors,
        )
        assertTrue(
            "ProbeEngineViewModel no longer constructs a SessionArchive: the field " +
                "may still exist, but nothing builds the cache",
            refs.calls(SESSION_ARCHIVE, "<init>"),
        )
    }

    @Test
    fun probeEngineViewModelCallsTheWholeSessionArchiveApi() {
        // The restore and save bodies live in Kotlin lambda classes
        // (`ProbeEngineViewModel$restoreSessionArchive$1`, `…$archiveCompletedTurn$1`),
        // so the whole family is read, not only the outer class file.
        val refs = allClassRefs("ProbeEngineViewModel")

        // The restore path: `currentSessionId()` + `latest()`.
        assertTrue(
            "the restore path no longer calls SessionArchive.currentSessionId()",
            refs.calls(SESSION_ARCHIVE, "currentSessionId"),
        )
        assertTrue(
            "the restore path no longer calls SessionArchive.latest()",
            refs.calls(SESSION_ARCHIVE, "latest"),
        )
        // The save path.
        assertTrue(
            "the save path no longer calls SessionArchive.save()",
            refs.calls(SESSION_ARCHIVE, "save"),
        )
    }

    @Test
    fun probeEngineViewModelKeepsTheRestoreAndSaveCallSites() {
        val refs = classRefs("com/phonedsh/probe/ProbeEngineViewModel.class")

        // Both are private methods with one call site each (the `init` block and
        // the completion branch). Deleting the call line leaves the method
        // declared but unreferenced, so the Methodref disappears — which is the
        // exact "implemented, then quietly unplugged" failure this guard exists
        // for. A method-table check would still pass; a call-site check cannot.
        assertTrue(
            "ProbeEngineViewModel no longer calls restoreSessionArchive(): a cold " +
                "start would stop painting the archived turn",
            refs.calls(SELF, "restoreSessionArchive"),
        )
        assertTrue(
            "ProbeEngineViewModel no longer calls archiveCompletedTurn(): a completed " +
                "turn would stop reaching the transcript cache",
            refs.calls(SELF, "archiveCompletedTurn"),
        )
    }

    @Test
    fun hostShellReloadsChatMetadataAfterEverySessionCommand() {
        // The HostShell session commands write ChatSessionStore directly. Reading
        // the compiled call sites proves every one of those paths asks the view
        // model to re-read the store; removing one leaves the two device symptoms
        // (stale archived count, renamed title overwritten by the next save).
        val callers = classFamily("HostShell").filter { (name, bytes) ->
            val input = DataInputStream(ByteArrayInputStream(bytes))
            val refs = try {
                readClass(input, name)
            } finally {
                input.close()
            }
            // Kotlin emits an internal method as `reloadChatMetadata$app_debug`,
            // so the compiled name is a prefix match rather than the source name.
            refs.methodRefs.any { (owner, method) ->
                owner == SELF && method.startsWith("reloadChatMetadata")
            }
        }.map { it.first }

        assertTrue(
            "HostShell no longer calls ProbeEngineViewModel.reloadChatMetadata from all " +
                "five session-command paths (rename/archive/restore actions, drawer rename, " +
                "drawer archive); found ${callers.size} call site(s): $callers",
            callers.size >= 5,
        )
    }

    @Test
    fun appLinksDomainAndDshDoesNot() {
        val app = moduleBuildFile("app").readText()
        val dsh = moduleBuildFile("dsh").readText()

        assertTrue(
            ":app must link :domain — it is the composition root that constructs " +
                "SessionArchive",
            app.contains("project(\":domain\")"),
        )
        assertFalse(
            ":dsh must not link :domain — the store backend is the app's choice, " +
                "not a library's",
            dsh.contains("project(\":domain\")"),
        )
    }

    // -----------------------------------------------------------------------
    // The class-file reader: just enough constant pool + field table
    // -----------------------------------------------------------------------

    /** One compiled class's method references and declared field descriptors. */
    private class ClassRefs(
        val methodRefs: Set<Pair<String, String>>,
        val fieldDescriptors: Set<String>,
    ) {
        /** True when some method ref names [owner] (internal name) and [method]. */
        fun calls(owner: String, method: String): Boolean = (owner to method) in methodRefs

        /** Every `owner#method` this class references, for a readable failure. */
        fun describe(): String = methodRefs
            .filter { it.first == SESSION_ARCHIVE || it.first == SELF }
            .sortedBy { it.second }
            .joinToString(", ") { "${it.first}#${it.second}" }
    }

    /** Reads [resource] (a `.class` on the test classpath) as a [ClassRefs]. */
    private fun classRefs(resource: String): ClassRefs {
        val stream = SessionArchiveWiringTest::class.java.classLoader
            ?.getResourceAsStream(resource)
            ?: throw AssertionError("$resource is not on the test classpath")
        val input = DataInputStream(ByteArrayInputStream(stream.use { it.readBytes() }))
        return try {
            readClass(input, resource)
        } finally {
            input.close()
        }
    }

    /**
     * The union of every compiled class whose name starts with [prefix].
     *
     * Kotlin puts a suspend function's body (and its `withContext` / `launch`
     * blocks) in a generated class beside the outer one, so a call such as
     * `SessionArchive.save` is a Methodref in `…$archiveCompletedTurn$1`, not in
     * `ProbeEngineViewModel` itself. Reading the family keeps the assertion about
     * behaviour ("the view model's code calls this") instead of about the
     * compiler's class layout.
     *
     * AGP hands the unit test the module's classes as a jar
     * (`bundleDebugClassesToRuntimeJar`), while a plain Kotlin test run sees a
     * directory; both layouts are read here, and anything else fails loudly
     * instead of silently weakening the assertion.
     */
    private fun allClassRefs(prefix: String): ClassRefs {
        val methodRefs = mutableSetOf<Pair<String, String>>()
        val fieldDescriptors = mutableSetOf<String>()
        val classes = classFamily(prefix)
        for ((name, bytes) in classes) {
            val input = DataInputStream(ByteArrayInputStream(bytes))
            val refs = try {
                readClass(input, name)
            } finally {
                input.close()
            }
            methodRefs.addAll(refs.methodRefs)
            fieldDescriptors.addAll(refs.fieldDescriptors)
        }
        return ClassRefs(methodRefs = methodRefs, fieldDescriptors = fieldDescriptors)
    }

    /** Every `.class` entry whose name starts with [prefix], sorted by name. */
    private fun classFamily(prefix: String): List<Pair<String, ByteArray>> {
        val directory = "com/phonedsh/probe/"
        val anchor = SessionArchiveWiringTest::class.java
            .getResource("/${directory}ProbeEngineViewModel.class")
            ?: throw AssertionError("ProbeEngineViewModel.class is not on the test classpath")
        val classes = when (anchor.protocol) {
            "file" -> {
                val packageDirectory = File(anchor.toURI()).parentFile
                    ?: throw AssertionError("cannot resolve the package directory of $anchor")
                val files = packageDirectory.listFiles { file ->
                    file.isFile && file.name.startsWith(prefix) && file.name.endsWith(".class")
                }.orEmpty()
                files.sortedBy { it.name }.map { it.name to it.readBytes() }
            }

            "jar" -> {
                val connection = anchor.openConnection() as java.net.JarURLConnection
                val jar = connection.jarFile
                val entries = mutableListOf<Pair<String, ByteArray>>()
                val enumeration = jar.entries()
                while (enumeration.hasMoreElements()) {
                    val entry = enumeration.nextElement()
                    if (entry.isDirectory) continue
                    if (!entry.name.startsWith("$directory$prefix")) continue
                    if (!entry.name.endsWith(".class")) continue
                    entries.add(entry.name to jar.getInputStream(entry).use { it.readBytes() })
                }
                entries.sortedBy { it.first }
            }

            else -> throw AssertionError(
                "expected the app's classes as a directory or jar, found ${anchor.protocol}:$anchor",
            )
        }
        if (classes.isEmpty()) {
            throw AssertionError("no ${prefix}*.class entries under $directory")
        }
        return classes
    }

    private fun readClass(input: DataInputStream, resource: String): ClassRefs {
        val magic = input.readInt()
        if (magic != CLASS_MAGIC) throw AssertionError("$resource is not a class file")
        input.readUnsignedShort() // minor
        input.readUnsignedShort() // major

        val poolCount = input.readUnsignedShort()
        val utf8 = arrayOfNulls<String>(poolCount)
        val classNames = IntArray(poolCount)
        val nameAndTypeNames = IntArray(poolCount)
        val nameAndTypeDescriptors = IntArray(poolCount)
        val methodRefs = mutableListOf<Pair<Int, Int>>()

        var index = 1
        while (index < poolCount) {
            when (val tag = input.readUnsignedByte()) {
                CONSTANT_UTF8 -> utf8[index] = input.readUTF()
                CONSTANT_CLASS -> classNames[index] = input.readUnsignedShort()
                CONSTANT_STRING, CONSTANT_METHOD_TYPE, CONSTANT_MODULE, CONSTANT_PACKAGE ->
                    input.readUnsignedShort()

                CONSTANT_METHOD_HANDLE -> {
                    input.readUnsignedByte()
                    input.readUnsignedShort()
                }

                CONSTANT_FIELD_REF, CONSTANT_METHOD_REF, CONSTANT_INTERFACE_METHOD_REF,
                CONSTANT_NAME_AND_TYPE, CONSTANT_DYNAMIC, CONSTANT_INVOKE_DYNAMIC -> {
                    val first = input.readUnsignedShort()
                    val second = input.readUnsignedShort()
                    when (tag) {
                        CONSTANT_METHOD_REF, CONSTANT_INTERFACE_METHOD_REF ->
                            methodRefs.add(first to second)

                        CONSTANT_NAME_AND_TYPE -> {
                            nameAndTypeNames[index] = first
                            nameAndTypeDescriptors[index] = second
                        }
                    }
                }

                CONSTANT_INTEGER, CONSTANT_FLOAT -> input.readInt()
                CONSTANT_LONG, CONSTANT_DOUBLE -> {
                    input.readLong()
                    // A long/double takes two constant-pool slots.
                    index += 1
                }

                else -> throw AssertionError("$resource: unknown constant-pool tag $tag")
            }
            index += 1
        }

        // access_flags, this_class, super_class.
        input.readUnsignedShort()
        input.readUnsignedShort()
        input.readUnsignedShort()
        repeat(input.readUnsignedShort()) { input.readUnsignedShort() } // interfaces

        val fieldDescriptors = mutableSetOf<String>()
        repeat(input.readUnsignedShort()) {
            input.readUnsignedShort() // access
            input.readUnsignedShort() // name_index
            val descriptorIndex = input.readUnsignedShort()
            fieldDescriptors.add(utf8[descriptorIndex] ?: "")
            repeat(input.readUnsignedShort()) {
                input.readUnsignedShort() // attribute_name_index
                skip(input, input.readInt().toLong())
            }
        }

        val resolved = methodRefs.mapNotNull { (classIndex, nameAndTypeIndex) ->
            val owner = utf8[classNames[classIndex]] ?: return@mapNotNull null
            val method = utf8[nameAndTypeNames[nameAndTypeIndex]] ?: return@mapNotNull null
            // The descriptor is read to prove the entry is well-formed; a
            // NameAndType without one cannot name a method.
            if (utf8[nameAndTypeDescriptors[nameAndTypeIndex]] == null) return@mapNotNull null
            owner to method
        }.toSet()

        return ClassRefs(methodRefs = resolved, fieldDescriptors = fieldDescriptors)
    }

    private fun skip(input: DataInputStream, count: Long) {
        var remaining = count
        while (remaining > 0) {
            val skipped = input.skip(remaining)
            if (skipped <= 0) {
                input.readByte()
                remaining -= 1
            } else {
                remaining -= skipped
            }
        }
    }

    // -----------------------------------------------------------------------
    // Module build files
    // -----------------------------------------------------------------------

    /**
     * `android/<module>/build.gradle.kts`, found from either the module
     * directory (Gradle's test working directory) or the repository root.
     */
    private fun moduleBuildFile(module: String): File {
        val workingDirectory = File(".").absoluteFile
        val candidates = listOf(
            // Gradle runs a module's tests with that module as the working
            // directory: `:app`'s suite sees `../dsh/...`.
            File(workingDirectory, "../$module/build.gradle.kts"),
            File(workingDirectory, "$module/build.gradle.kts"),
            File(workingDirectory, "android/$module/build.gradle.kts"),
        )
        return candidates.firstOrNull { it.isFile }
            ?: throw AssertionError(
                "cannot find :$module's build file from ${workingDirectory.path}; " +
                    "the test expects Gradle's module working directory or the repo root",
            )
    }

    private companion object {
        /** The class-file magic (`0xCAFEBABE`), as the signed int `readInt` returns. */
        const val CLASS_MAGIC: Int = -0x35014542

        const val CONSTANT_UTF8: Int = 1
        const val CONSTANT_INTEGER: Int = 3
        const val CONSTANT_FLOAT: Int = 4
        const val CONSTANT_LONG: Int = 5
        const val CONSTANT_DOUBLE: Int = 6
        const val CONSTANT_CLASS: Int = 7
        const val CONSTANT_STRING: Int = 8
        const val CONSTANT_FIELD_REF: Int = 9
        const val CONSTANT_METHOD_REF: Int = 10
        const val CONSTANT_INTERFACE_METHOD_REF: Int = 11
        const val CONSTANT_NAME_AND_TYPE: Int = 12
        const val CONSTANT_METHOD_HANDLE: Int = 15
        const val CONSTANT_METHOD_TYPE: Int = 16
        const val CONSTANT_DYNAMIC: Int = 17
        const val CONSTANT_INVOKE_DYNAMIC: Int = 18
        const val CONSTANT_MODULE: Int = 19
        const val CONSTANT_PACKAGE: Int = 20

        const val SELF: String = "com/phonedsh/probe/ProbeEngineViewModel"
        const val SESSION_ARCHIVE: String = "com/phonedsh/domain/session/SessionArchive"
        const val SESSION_ARCHIVE_DESCRIPTOR: String = "L$SESSION_ARCHIVE;"
    }
}
