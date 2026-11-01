// The thin JNI binding to the WAL kernel (`pdsh-wal`). No format logic.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * The native half of the I/O-free WAL kernel (`pdsh-wal`), **experimental**.
 *
 * **The WAL ABI is not frozen before the R1 conclusion** (Android adaptation
 * plan §8.2-2). These entry points, their JSON shapes and their error codes may
 * change with the WAL semantics; a caller must not treat them as a frozen
 * format contract yet. The Rust side performs **no I/O**: every call takes
 * bytes or JSON and returns bytes or JSON, and the caller reads/writes files,
 * orders fsyncs and applies the recovery plan.
 *
 * The Rust crate `pdsh-jni` exports the symbols
 * `Java_com_phonedsh_wire_NativeWal_<name>Native`; the class name is fixed so
 * the exported names do not depend on Kotlin compilation details. When
 * `System.loadLibrary("pdsh_jni")` failed, every method throws
 * [WireUnavailable] instead of returning an empty string or a default verdict.
 *
 * Native failures are translated into the typed exceptions of the wire
 * package: a `"<CODE>: <detail>"` message becomes [WalException] (with the
 * [WalErrorCode] table), and a `"PDSH_JNI_PANIC: ..."` message becomes
 * [WirePanicException]. The native calls stay private except the test-only
 * [panicForTestNative] hook.
 *
 * ### R8 keep rule
 *
 * On Android release builds R8 must keep the native method names: they are
 * resolved by `System.loadLibrary` at runtime, not through a Java call site.
 * The packaging module needs a rule such as
 * ```
 * -keepclasseswithmembernames class com.phonedsh.wire.NativeWal { native <methods>; }
 * ```
 * This module is pure JVM and does not ship that rule itself.
 */
object NativeWal {
    /** Name passed to `System.loadLibrary`; resolves to `libpdsh_jni.so`/`.dylib`. */
    private const val LIBRARY_NAME = "pdsh_jni"

    private val binding = NativeWalBinding(
        load = { System.loadLibrary(LIBRARY_NAME) },
        calls = JniCalls,
    )

    /** Whether the native library loaded. */
    val available: Boolean
        get() = binding.available

    /** The load failure, or `null` when [available]. */
    val failure: Throwable?
        get() = binding.failure

    /**
     * D19 tail classification of one **whole segment file** (header included).
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     * Returns `{"verdict":"clean"}`, `{"verdict":"truncate","keep":N,
     * "dropped":N}` or `{"verdict":"corrupt","at":N}` with file offsets.
     *
     * @throws WalException `WAL_TRUNCATED` when the input is shorter than the
     *   40-byte header.
     * @throws WireUnavailable the native library is not available.
     */
    fun classifyTail(segment: ByteArray): String =
        translate("classifyTail") { binding.classifyTail(segment) }

    /**
     * One segment's facts plus `chain_error`, `header_error` and `valid_len`.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     *
     * @throws WireUnavailable the native library is not available.
     */
    fun scanSegment(segment: ByteArray): String =
        translate("scanSegment") { binding.scanSegment(segment) }

    /**
     * The D11 recovery plan for one `wal/` directory.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     *
     * @throws WalException a coded plan failure; an invalid embedded manifest
     *   is `WAL_MANIFEST_INVALID` and is never silently ignored.
     * @throws WireUnavailable the native library is not available.
     */
    fun planRecovery(input: String): String =
        translate("planRecovery") { binding.planRecovery(input) }

    /**
     * `manifest.json` bytes to the canonical JSON object.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     *
     * @throws WalException `WAL_MANIFEST_INVALID` for a schema-invalid file.
     * @throws WireUnavailable the native library is not available.
     */
    fun parseManifest(manifest: ByteArray): String =
        translate("parseManifest") { binding.parseManifest(manifest) }

    /**
     * A manifest JSON object to canonical `manifest.json` bytes.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     *
     * @throws WalException `WAL_MANIFEST_INVALID` for a schema-invalid object.
     * @throws WireUnavailable the native library is not available.
     */
    fun emitManifest(manifestJson: String): ByteArray =
        translate("emitManifest") { binding.emitManifest(manifestJson) }

    /**
     * One complete record frame's CRC and structure.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     * Returns `{"ok":true}` or `{"ok":false,"code":...,"detail":...,
     * "tail_eligible":...}`; a bad frame is a value here, not an exception.
     *
     * @throws WireUnavailable the native library is not available.
     */
    fun verifyRecord(record: ByteArray): String =
        translate("verifyRecord") { binding.verifyRecord(record) }

    /**
     * Every complete, CRC-verified record of one whole segment file, decoded.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     * Returns a JSON array in file order; each element carries `mseq`, `len`,
     * `crc_ok`, `kind` and the decoded body (`op`, `mode`, `mflags`,
     * `append_from`, `path`, `data_len`, `data_hex` for a mutation, or
     * `wall_ms`, `durable_upto` for an epoch close). A D19 torn tail is
     * omitted rather than decoded; call [classifyTail] for that verdict.
     *
     * @throws WalException `WAL_HEADER_INVALID`/`WAL_TRUNCATED` for an
     *   unreadable header, `WAL_CORRUPT` for a non-tail failure or an mseq hole.
     * @throws WireUnavailable the native library is not available.
     */
    fun records(segment: ByteArray): String =
        translate("records") { binding.records(segment) }

    /**
     * Exactly one complete record frame, decoded to the object [records] emits.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     *
     * @throws WalException `WAL_TRUNCATED` for a short frame, `WAL_CORRUPT`
     *   for a CRC/malformed frame, `WAL_INPUT_INVALID` for trailing bytes.
     * @throws WireUnavailable the native library is not available.
     */
    fun decodeRecord(record: ByteArray): String =
        translate("decodeRecord") { binding.decodeRecord(record) }

    /**
     * The D9 idempotent appended-replay verdict (`wal.md` §6.2).
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     * [existingAtOffset] is the materialized file's bytes starting at
     * [appendFrom], or `null` when the path is absent, is a directory or is not
     * a regular file. Returns `{"verdict":"applied"}`, `{"verdict":"skip"}` or
     * `{"verdict":"resync"}`.
     *
     * @throws WalException `WAL_INPUT_INVALID` for a negative size or offset.
     * @throws WireUnavailable the native library is not available.
     */
    fun appendedReplay(
        currentSize: Long,
        appendFrom: Long,
        data: ByteArray,
        existingAtOffset: ByteArray?,
    ): String = translate("appendedReplay") {
        binding.appendedReplay(currentSize, appendFrom, data, existingAtOffset)
    }

    /**
     * Test-only panic hook: always panics inside the Rust entry point.
     *
     * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
     * This is the one native method that is not wrapped: the panic must reach
     * the test as the JVM exception `pdsh-jni` throws, not as a translated
     * [WirePanicException], so the suite proves the raw boundary and can then
     * call [scanSegment] again to prove the process state is intact.
     */
    @JvmName("panicForTestNative")
    internal external fun panicForTestNative(message: String): String

    private external fun classifyTailNative(segment: ByteArray): String

    private external fun scanSegmentNative(segment: ByteArray): String

    private external fun planRecoveryNative(input: String): String

    private external fun parseManifestNative(manifest: ByteArray): String

    private external fun emitManifestNative(manifestJson: String): ByteArray

    private external fun verifyRecordNative(record: ByteArray): String

    private external fun recordsNative(segment: ByteArray): String

    private external fun decodeRecordNative(record: ByteArray): String

    private external fun appendedReplayNative(
        currentSize: Long,
        appendFrom: Long,
        data: ByteArray,
        existingAtOffset: ByteArray?,
    ): String

    private inline fun <T> translate(operation: String, block: () -> T): T =
        try {
            block()
        } catch (unavailable: WireUnavailable) {
            throw unavailable
        } catch (error: RuntimeException) {
            throw WalErrors.translate(operation, error)
        }

    private object JniCalls : NativeWalCalls {
        override fun classifyTail(segment: ByteArray): String =
            NativeWal.classifyTailNative(segment)

        override fun scanSegment(segment: ByteArray): String =
            NativeWal.scanSegmentNative(segment)

        override fun planRecovery(input: String): String =
            NativeWal.planRecoveryNative(input)

        override fun parseManifest(manifest: ByteArray): String =
            NativeWal.parseManifestNative(manifest)

        override fun emitManifest(manifestJson: String): ByteArray =
            NativeWal.emitManifestNative(manifestJson)

        override fun verifyRecord(record: ByteArray): String =
            NativeWal.verifyRecordNative(record)

        override fun records(segment: ByteArray): String =
            NativeWal.recordsNative(segment)

        override fun decodeRecord(record: ByteArray): String =
            NativeWal.decodeRecordNative(record)

        override fun appendedReplay(
            currentSize: Long,
            appendFrom: Long,
            data: ByteArray,
            existingAtOffset: ByteArray?,
        ): String = NativeWal.appendedReplayNative(currentSize, appendFrom, data, existingAtOffset)
    }
}

/**
 * The native operations behind [NativeWal], split out so the load-failure
 * branch can be tested without a second JVM or class loader.
 *
 * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
 */
internal interface NativeWalCalls {
    fun classifyTail(segment: ByteArray): String

    fun scanSegment(segment: ByteArray): String

    fun planRecovery(input: String): String

    fun parseManifest(manifest: ByteArray): String

    fun emitManifest(manifestJson: String): ByteArray

    fun verifyRecord(record: ByteArray): String

    fun records(segment: ByteArray): String

    fun decodeRecord(record: ByteArray): String

    fun appendedReplay(
        currentSize: Long,
        appendFrom: Long,
        data: ByteArray,
        existingAtOffset: ByteArray?,
    ): String
}

/**
 * Loads the native library once and routes every call through one availability
 * check.
 *
 * @param load performs `System.loadLibrary` (or any throwing loader).
 * @param calls the native implementations; never invoked when [available] is
 *   false, which is what makes the stub honest.
 */
internal class NativeWalBinding(
    load: () -> Unit,
    private val calls: NativeWalCalls,
) {
    /** Whether [load] completed without throwing. */
    val available: Boolean

    /** The [load] failure, or `null` when [available]. */
    val failure: Throwable?

    init {
        var cause: Throwable? = null
        try {
            load()
        } catch (error: Throwable) {
            cause = error
        }
        available = cause == null
        failure = cause
    }

    fun classifyTail(segment: ByteArray): String = guarded { calls.classifyTail(segment) }

    fun scanSegment(segment: ByteArray): String = guarded { calls.scanSegment(segment) }

    fun planRecovery(input: String): String = guarded { calls.planRecovery(input) }

    fun parseManifest(manifest: ByteArray): String = guarded { calls.parseManifest(manifest) }

    fun emitManifest(manifestJson: String): ByteArray =
        guarded { calls.emitManifest(manifestJson) }

    fun verifyRecord(record: ByteArray): String = guarded { calls.verifyRecord(record) }

    fun records(segment: ByteArray): String = guarded { calls.records(segment) }

    fun decodeRecord(record: ByteArray): String = guarded { calls.decodeRecord(record) }

    fun appendedReplay(
        currentSize: Long,
        appendFrom: Long,
        data: ByteArray,
        existingAtOffset: ByteArray?,
    ): String = guarded {
        calls.appendedReplay(currentSize, appendFrom, data, existingAtOffset)
    }

    private inline fun <T> guarded(block: () -> T): T {
        if (!available) {
            throw WireUnavailable(failure)
        }
        return block()
    }
}

/**
 * Maps the native WAL exception ABI to the typed Kotlin exceptions.
 *
 * The Rust side throws only `java.lang.RuntimeException`:
 *
 * - `"CODE: detail"` with a `WAL_*` code → [WalException] (the code is kept
 *   even when it is not in [WalErrorCode], so a newer Rust table is not lost);
 * - `"PDSH_JNI_PANIC: <operation>: <detail>"` → [WirePanicException];
 * - anything else is a JNI-level failure and is rethrown unchanged.
 *
 * **Experimental**: the WAL ABI is not frozen before the R1 conclusion.
 */
internal object WalErrors {
    private const val PANIC_PREFIX = "PDSH_JNI_PANIC: "
    private val CODE = Regex("[A-Z][A-Z0-9_]*")

    fun translate(operation: String, error: RuntimeException): RuntimeException {
        val message = error.message ?: return error
        if (message.startsWith(PANIC_PREFIX)) {
            val rest = message.removePrefix(PANIC_PREFIX)
            val separator = rest.indexOf(": ")
            val detail = if (separator >= 0) rest.substring(separator + 2) else rest
            return WirePanicException(operation, detail, error)
        }
        val separator = message.indexOf(": ")
        if (separator <= 0) {
            return error
        }
        val code = message.substring(0, separator)
        if (!CODE.matches(code)) {
            return error
        }
        return WalException(code, message.substring(separator + 2), error)
    }
}
