// phone-dsh — :app / com.phonedsh.ssh: one saved SSH connection and its pinned transport.
// SPDX-License-Identifier: MIT
//
// Android half of `Sources/PhoneDSHSSH/SSHConnection.swift` (docs/native-ssh.md,
// PC-20261105-native-ssh-adb). The rules are the iOS ones:
//
//   * credentials stay in this process; only the connection alias reaches the
//     Worker. The app's Keystore-backed resolver builds this value per call;
//   * a connection without a trusted host key is refused before any network
//     access, and a connection only ever accepts the one pinned key (no TOFU at
//     connect time, no known_hosts file, no "add on first use");
//   * `inspectHostKey` deliberately rejects the handshake before authentication,
//     so the settings page can show the SHA-256 fingerprint for the person to
//     confirm; nothing is trusted until they do;
//   * cancellation and the deadline close the TCP socket during the handshake
//     too, not only after authentication.
//
// The SSH implementation is JSch (com.github.mwiede:jsch, BSD). EdDSA (Ed25519
// keys and host keys) and X25519 key exchange use JSch's Bouncy Castle
// lightweight-API classes, selected explicitly below: Android API 26 has no JCA
// EdDSA/XDH, and a JVM test that silently used the JDK's EdDSA would not prove
// what the device runs. The algorithm lists are JSch's defaults, which exclude
// SHA-1 `ssh-rsa` signatures; the pinned host key additionally fixes the host
// key algorithm family to the pinned key's own type.

package com.phonedsh.ssh

import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.KeyPair
import com.jcraft.jsch.Logger
import com.jcraft.jsch.Session
import com.jcraft.jsch.UserInfo
import java.io.ByteArrayOutputStream
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.util.Base64

/** A user-facing SSH failure; the message is safe to show and never carries a secret. */
class SshFailure(message: String) : Exception(message)

/**
 * One resolved connection. The secret members never appear in [toString].
 *
 * @param trustedHostKey the pinned server key as one OpenSSH public-key line
 *   (`ssh-ed25519 AAAA…`); empty means "not verified" and refuses every connect.
 */
class SshConnection(
    val host: String,
    val port: Int = 22,
    val username: String,
    val password: String = "",
    val privateKey: String = "",
    val passphrase: String = "",
    val trustedHostKey: String,
) {
    override fun toString(): String = "SshConnection(redacted)"

    fun copy(
        host: String = this.host,
        port: Int = this.port,
        username: String = this.username,
        password: String = this.password,
        privateKey: String = this.privateKey,
        passphrase: String = this.passphrase,
        trustedHostKey: String = this.trustedHostKey,
    ): SshConnection = SshConnection(host, port, username, password, privateKey, passphrase, trustedHostKey)
}

/**
 * Owns one connection attempt so another thread can close it at any stage.
 *
 * `cancel` is idempotent and safe before, during and after the handshake: a
 * session attached after a cancel is closed immediately.
 */
class SshCancellation {
    private val lock = Any()
    private var session: Session? = null
    private var stopped = false
    private var deadline = false

    val cancelled: Boolean get() = synchronized(lock) { stopped }
    val timedOut: Boolean get() = synchronized(lock) { deadline }

    internal fun attach(value: Session) {
        val close = synchronized(lock) {
            session = value
            stopped
        }
        if (close) value.disconnect()
    }

    /** Closes the attached session (if any); [timeout] records a deadline rather than a cancel. */
    fun cancel(timeout: Boolean = false) {
        val current = synchronized(lock) {
            stopped = true
            deadline = deadline || timeout
            session
        }
        current?.disconnect()
    }

    /** Releases the session at the end of a run (not a cancellation). */
    fun close() {
        val current = synchronized(lock) {
            val value = session
            session = null
            value
        }
        current?.disconnect()
    }
}

/** The connect / inspect / fingerprint operations over JSch. */
object SshTransport {
    init {
        // Select the Bouncy Castle lightweight implementations explicitly (see
        // the file header). The keys are JSch's own configuration names.
        JSch.setConfig("xdh", "com.jcraft.jsch.bc.XDH")
        JSch.setConfig("keypairgen.eddsa", "com.jcraft.jsch.bc.KeyPairGenEdDSA")
        JSch.setConfig("keypairgen_fromprivate.eddsa", "com.jcraft.jsch.bc.KeyPairGenEdDSA")
        JSch.setConfig("ssh-ed25519", "com.jcraft.jsch.bc.SignatureEd25519")
        JSch.setConfig("ssh-ed448", "com.jcraft.jsch.bc.SignatureEd448")
    }

    private const val OPENSSH_KEY_HEADER = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private const val CONTINUE_PREFIX = "Authentications that can continue: "
    private const val MAX_CONNECT_TIMEOUT_MS = 15_000L

    /**
     * Opens an authenticated session that accepts only the pinned host key.
     *
     * @param timeoutMs the remaining request budget; the socket/handshake bound
     *   is `min(15 s, timeoutMs)` like iOS's `connectTimeout`.
     * @param cancellation closes the socket from another thread at any stage.
     */
    fun connect(connection: SshConnection, timeoutMs: Long, cancellation: SshCancellation): Session {
        validateEndpoint(connection.host, connection.port)
        if (connection.username.isEmpty() || connection.username.contains('\u0000')) {
            throw SshFailure("Invalid SSH host, port or username")
        }
        if (connection.trustedHostKey.isEmpty()) {
            throw SshFailure("Server key is not trusted. Verify the connection in Settings → SSH first.")
        }
        val pinned = PublicKeyLine.parse(connection.trustedHostKey)
            ?: throw SshFailure("The trusted server key is invalid. Verify the connection in Settings → SSH again.")
        val hostKeyAlgorithms = hostKeyAlgorithmsFor(pinned.type)
            ?: throw SshFailure("Unsupported trusted server key type ${pinned.type}")

        val jsch = JSch()
        val continuations = AuthMethodsLogger()
        jsch.setInstanceLogger(continuations)
        jsch.setHostKeyRepository(PinnedHostKeyRepository(pinned.blob))
        val usesKey = connection.privateKey.isNotEmpty()
        if (usesKey) addIdentity(jsch, connection.privateKey, connection.passphrase)

        val session = jsch.getSession(connection.username, connection.host, connection.port)
        session.setConfig("StrictHostKeyChecking", "yes")
        session.setConfig("HashKnownHosts", "no")
        session.setConfig("server_host_key", hostKeyAlgorithms)
        session.setConfig("PreferredAuthentications", if (usesKey) "publickey" else "password")
        if (!usesKey) session.setPassword(connection.password.toByteArray(Charsets.UTF_8))
        cancellation.attach(session)
        try {
            session.connect(boundedTimeout(timeoutMs))
        } catch (failure: JSchException) {
            session.disconnect()
            if (cancellation.cancelled) throw SshFailure(if (cancellation.timedOut) "SSH deadline exceeded" else "SSH cancelled")
            throw mapConnectFailure(failure, usesKey, continuations.methods)
        }
        if (cancellation.cancelled) {
            session.disconnect()
            throw SshFailure(if (cancellation.timedOut) "SSH deadline exceeded" else "SSH cancelled")
        }
        return session
    }

    /**
     * Observes the server key and rejects the handshake before authentication.
     *
     * JSch verifies the server's signature over the exchange hash before it asks
     * the repository, so the returned key is one the server proved it holds.
     * The settings page asks the person to trust this exact key.
     */
    fun inspectHostKey(
        host: String,
        port: Int = 22,
        timeoutMs: Long = 10_000L,
        cancellation: SshCancellation = SshCancellation(),
    ): String {
        validateEndpoint(host, port, message = "Invalid host or port")
        val jsch = JSch()
        val capture = CapturingHostKeyRepository()
        jsch.setHostKeyRepository(capture)
        val session = jsch.getSession("key-verification", host, port)
        session.setConfig("StrictHostKeyChecking", "yes")
        session.setConfig("PreferredAuthentications", "none")
        cancellation.attach(session)
        try {
            session.connect(boundedTimeout(timeoutMs))
        } catch (failure: JSchException) {
            if (capture.key == null) {
                if (cancellation.cancelled) throw SshFailure("SSH cancelled")
                throw mapConnectFailure(failure, usesKey = false, methods = null)
            }
        } finally {
            session.disconnect()
        }
        return capture.key ?: throw SshFailure("Server did not provide a host key")
    }

    /** `SHA256:<unpadded base64>` of the key blob, the OpenSSH fingerprint form. */
    fun fingerprint(key: String): String {
        val parsed = PublicKeyLine.parse(key) ?: return "Invalid key"
        val digest = MessageDigest.getInstance("SHA-256").digest(parsed.blob)
        return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
    }

    private fun validateEndpoint(host: String, port: Int, message: String = "Invalid SSH host, port or username") {
        if (host.isEmpty() || host.contains('\u0000') || host.any { it.isWhitespace() } || port !in 1..65535) {
            throw SshFailure(message)
        }
    }

    private fun boundedTimeout(timeoutMs: Long): Int =
        timeoutMs.coerceIn(1L, MAX_CONNECT_TIMEOUT_MS).toInt()

    /**
     * The host-key algorithms that can present a key of the pinned [type].
     *
     * An RSA key is offered with the SHA-2 signature algorithms only; the
     * SHA-1 `ssh-rsa` signature is not enabled to reach an old server.
     */
    internal fun hostKeyAlgorithmsFor(type: String): String? = when (type) {
        "ssh-ed25519", "ssh-ed448",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521" -> type
        "ssh-rsa" -> "rsa-sha2-512,rsa-sha2-256"
        else -> null
    }

    private fun addIdentity(jsch: JSch, privateKey: String, passphrase: String) {
        val normalized = privateKey.replace("\r\n", "\n").trim()
        val failure = SshFailure(
            "Invalid OpenSSH Ed25519/RSA private key or passphrase",
        )
        if (!normalized.startsWith(OPENSSH_KEY_HEADER)) throw failure
        val bytes = normalized.toByteArray(Charsets.UTF_8)
        val pair = try {
            KeyPair.load(jsch, bytes, null)
        } catch (invalid: JSchException) {
            throw failure
        }
        try {
            // An encrypted openssh-key-v1 key only reveals its type after
            // decryption, so decrypt first and check the type afterwards.
            if (pair.isEncrypted && (passphrase.isEmpty() || !pair.decrypt(passphrase.toByteArray(Charsets.UTF_8)))) {
                throw failure
            }
            if (pair.keyType != KeyPair.ED25519 && pair.keyType != KeyPair.RSA) throw failure
        } finally {
            pair.dispose()
        }
        try {
            jsch.addIdentity(
                "pdsh-saved-key",
                bytes,
                null,
                if (passphrase.isEmpty()) null else passphrase.toByteArray(Charsets.UTF_8),
            )
        } catch (invalid: JSchException) {
            throw failure
        }
    }

    private fun mapConnectFailure(failure: JSchException, usesKey: Boolean, methods: Set<String>?): SshFailure {
        val message = failure.message.orEmpty()
        if (message.startsWith("Auth fail") || message.startsWith("Auth cancel")) {
            if (!usesKey) {
                return if (methods != null && "password" !in methods) {
                    SshFailure("Server does not allow password authentication. Configure an authorized key in Settings → SSH.")
                } else {
                    SshFailure(
                        "SSH authentication failed: the server rejected the password or requires an authorized key. " +
                            "Check Settings → SSH; do not keep retrying the same credential.",
                    )
                }
            }
            return if (methods != null && "publickey" !in methods) {
                SshFailure("Server does not allow this SSH key authentication method.")
            } else {
                SshFailure("SSH key authentication failed. Check the username and whether this public key is authorized on the server.")
            }
        }
        if (message.startsWith("HostKey has been changed") || message.startsWith("reject HostKey")) {
            return SshFailure(
                "Server host key does not match the trusted key. Verify the fingerprint again in Settings → SSH before reconnecting.",
            )
        }
        if (failure.cause is SocketTimeoutException || message.contains("timeout", ignoreCase = true)) {
            return SshFailure("SSH connection timed out")
        }
        if (message.startsWith("Algorithm negotiation fail")) {
            return SshFailure("SSH algorithm negotiation failed: the server does not offer a supported algorithm for the trusted key")
        }
        val cause = failure.cause?.let { ": ${it.javaClass.simpleName}" }.orEmpty()
        return SshFailure("SSH connection failed: ${message.ifEmpty { failure.javaClass.simpleName }}$cause")
    }

    /** Records only JSch's "methods that can continue" line; it carries no secret. */
    private class AuthMethodsLogger : Logger {
        @Volatile
        var methods: Set<String>? = null

        override fun isEnabled(level: Int): Boolean = level == Logger.INFO

        override fun log(level: Int, message: String?) {
            if (level != Logger.INFO || message == null || !message.startsWith(CONTINUE_PREFIX)) return
            methods = message.removePrefix(CONTINUE_PREFIX).split(',').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        }
    }
}

/** One `type base64 [comment]` OpenSSH public-key line, with its decoded blob. */
internal class PublicKeyLine private constructor(val type: String, val blob: ByteArray) {
    fun encoded(): String = type + " " + Base64.getEncoder().encodeToString(blob)

    companion object {
        fun parse(line: String): PublicKeyLine? {
            val fields = line.trim().split(' ').filter { it.isNotEmpty() }
            if (fields.size < 2) return null
            val blob = try {
                Base64.getDecoder().decode(fields[1])
            } catch (invalid: IllegalArgumentException) {
                return null
            }
            // The blob's first SSH string is the key type; it must agree with the label.
            if (blob.size < 4) return null
            val length = ((blob[0].toInt() and 0xff) shl 24) or ((blob[1].toInt() and 0xff) shl 16) or
                ((blob[2].toInt() and 0xff) shl 8) or (blob[3].toInt() and 0xff)
            if (length <= 0 || length > blob.size - 4) return null
            val embedded = String(blob, 4, length, Charsets.US_ASCII)
            if (embedded != fields[0]) return null
            return PublicKeyLine(fields[0], blob)
        }

        fun of(blob: ByteArray): PublicKeyLine? {
            if (blob.size < 4) return null
            val length = ((blob[0].toInt() and 0xff) shl 24) or ((blob[1].toInt() and 0xff) shl 16) or
                ((blob[2].toInt() and 0xff) shl 8) or (blob[3].toInt() and 0xff)
            if (length <= 0 || length > blob.size - 4) return null
            return PublicKeyLine(String(blob, 4, length, Charsets.US_ASCII), blob.copyOf())
        }
    }
}

/** Accepts exactly one key blob; it never learns or stores another key. */
private class PinnedHostKeyRepository(private val pinned: ByteArray) : HostKeyRepository {
    override fun check(host: String?, key: ByteArray?): Int =
        if (key != null && MessageDigest.isEqual(key, pinned)) HostKeyRepository.OK else HostKeyRepository.CHANGED

    override fun add(hostkey: HostKey?, ui: UserInfo?) = Unit

    override fun remove(host: String?, type: String?) = Unit

    override fun remove(host: String?, type: String?, key: ByteArray?) = Unit

    override fun getKnownHostsRepositoryID(): String = "pdsh-pinned-host-key"

    override fun getHostKey(): Array<HostKey> = emptyArray()

    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
}

/** Records the server's (signature-verified) key and refuses it, ending the handshake. */
private class CapturingHostKeyRepository : HostKeyRepository {
    @Volatile
    var key: String? = null

    override fun check(host: String?, key: ByteArray?): Int {
        if (key != null) this.key = PublicKeyLine.of(key)?.encoded()
        return HostKeyRepository.NOT_INCLUDED
    }

    override fun add(hostkey: HostKey?, ui: UserInfo?) = Unit

    override fun remove(host: String?, type: String?) = Unit

    override fun remove(host: String?, type: String?, key: ByteArray?) = Unit

    override fun getKnownHostsRepositoryID(): String = "pdsh-host-key-inspection"

    override fun getHostKey(): Array<HostKey> = emptyArray()

    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
}

/** A byte sink with a shared ceiling; writes past it flip [exceeded] instead of growing. */
internal class BoundedSink(private val budget: SharedBudget) : java.io.OutputStream() {
    private val buffer = ByteArrayOutputStream()

    override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

    override fun write(b: ByteArray, off: Int, len: Int) {
        if (!budget.take(len)) return
        synchronized(buffer) { buffer.write(b, off, len) }
    }

    fun bytes(): ByteArray = synchronized(buffer) { buffer.toByteArray() }
}

/** The combined stdout + stderr allowance of one command. */
internal class SharedBudget(private val limit: Long) {
    private var used = 0L

    @Volatile
    var exceeded: Boolean = false
        private set

    @Synchronized
    fun take(count: Int): Boolean {
        if (exceeded) return false
        if (used + count > limit) {
            exceeded = true
            return false
        }
        used += count
        return true
    }
}
