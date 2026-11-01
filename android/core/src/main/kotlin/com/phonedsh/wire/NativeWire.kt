// The thin JNI binding to `libpdsh_jni` (Rust `pdsh-wire`). No codec logic.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * The native half of the wire codec.
 *
 * The Rust crate `pdsh-jni` exports the symbols
 * `Java_com_phonedsh_wire_NativeWire_<name>Native`; the class name is fixed so
 * the exported names do not depend on Kotlin compilation details. Every public
 * method of this object is guarded by [NativeWireBinding]: when
 * `System.loadLibrary("pdsh_jni")` failed, the method throws [WireUnavailable]
 * instead of returning an empty array or string.
 *
 * The native calls are intentionally private: callers use [WireCodec], which
 * is the only place that maps native `RuntimeException`s to [WireException] and
 * [WirePanicException]. The one exception is [panicForTest], which the test
 * suite uses to prove the panic boundary; it is `internal` and always panics.
 *
 * On Android release builds R8 must keep the native method names: they are
 * resolved by `System.loadLibrary` at runtime, not through a Java call site.
 * The packaging module needs a rule such as
 * `-keepclasseswithmembernames class com.phonedsh.wire.NativeWire { native <methods>; }`.
 * This module is pure JVM and does not ship that rule itself.
 */
object NativeWire {
    /** Name passed to `System.loadLibrary`; resolves to `libpdsh_jni.so`/`.dylib`. */
    private const val LIBRARY_NAME = "pdsh_jni"

    private val binding = NativeWireBinding(
        load = { System.loadLibrary(LIBRARY_NAME) },
        calls = JniCalls,
    )

    /** Whether the native library loaded. */
    val available: Boolean
        get() = binding.available

    /** The load failure, or `null` when [available]. */
    val failure: Throwable?
        get() = binding.failure

    /** CRC-32C of [bytes]; `crc32c("123456789") == 0xE3069283`. */
    fun crc32c(bytes: ByteArray): Int = binding.crc32c(bytes)

    /** Encodes a golden-`fields` frame JSON at [seq] (see [WireCodec.encode]). */
    fun encodeFrame(seq: Long, frameJson: String): ByteArray = binding.encodeFrame(seq, frameJson)

    /** Decodes a complete frame to the canonical JSON of its `fields`. */
    fun decodeFrame(bytes: ByteArray): String = binding.decodeFrame(bytes)

    /** Re-encodes [json] as canonical JSON (`channel.md` §5). */
    fun canonicalJson(json: String): String = binding.canonicalJson(json)

    /** Test-only panic hook: always panics inside the Rust entry point. */
    internal fun panicForTest(message: String): String = binding.panicForTest(message)

    private external fun crc32cNative(bytes: ByteArray): Int

    private external fun encodeFrameNative(seq: Long, frameJson: String): ByteArray

    private external fun decodeFrameNative(bytes: ByteArray): String

    private external fun canonicalJsonNative(json: String): String

    private external fun panicForTestNative(message: String): String

    private object JniCalls : NativeWireCalls {
        override fun crc32c(bytes: ByteArray): Int = NativeWire.crc32cNative(bytes)

        override fun encodeFrame(seq: Long, frameJson: String): ByteArray =
            NativeWire.encodeFrameNative(seq, frameJson)

        override fun decodeFrame(bytes: ByteArray): String = NativeWire.decodeFrameNative(bytes)

        override fun canonicalJson(json: String): String = NativeWire.canonicalJsonNative(json)

        override fun panicForTest(message: String): String =
            NativeWire.panicForTestNative(message)
    }
}

/**
 * The native operations behind [NativeWire], split out so the load-failure
 * branch can be tested without a second JVM or class loader.
 */
internal interface NativeWireCalls {
    fun crc32c(bytes: ByteArray): Int

    fun encodeFrame(seq: Long, frameJson: String): ByteArray

    fun decodeFrame(bytes: ByteArray): String

    fun canonicalJson(json: String): String

    fun panicForTest(message: String): String
}

/**
 * Loads the native library once and routes every call through one availability
 * check.
 *
 * @param load performs `System.loadLibrary` (or any throwing loader).
 * @param calls the native implementations; never invoked when [available] is
 *   false, which is what makes the stub honest.
 */
internal class NativeWireBinding(
    load: () -> Unit,
    private val calls: NativeWireCalls,
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

    fun crc32c(bytes: ByteArray): Int = guarded { calls.crc32c(bytes) }

    fun encodeFrame(seq: Long, frameJson: String): ByteArray =
        guarded { calls.encodeFrame(seq, frameJson) }

    fun decodeFrame(bytes: ByteArray): String = guarded { calls.decodeFrame(bytes) }

    fun canonicalJson(json: String): String = guarded { calls.canonicalJson(json) }

    fun panicForTest(message: String): String = guarded { calls.panicForTest(message) }

    private inline fun <T> guarded(block: () -> T): T {
        if (!available) {
            throw WireUnavailable(failure)
        }
        return block()
    }
}
