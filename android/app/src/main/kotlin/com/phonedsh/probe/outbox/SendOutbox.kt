// SPDX-License-Identifier: MIT
// Durable send outbox (P06, W1; spec/host/v1/README.md section 10).
//
// Kotlin end of `examples/probe-app/ProbeKit/Outbox/SendOutbox.swift`.
//
// Enqueue is the durable fact: `<root>/send-outbox/<rpcId>.json` is written with
// the section 7 order (temp, fsync, rename, directory fsync) before any
// transport attempt. `rpcId` is a lowercase UUIDv4 minted at enqueue and is the
// only idempotency key of the delivery; a retry reuses it and a restart never
// invents a new one. The file is removed only after authoritative history holds
// a user message with that `source.rpcId` and the entry reached `durable`.
//
// Attachments are references. The bytes live at
// `send-outbox/attachments/<rpcId>/<attachmentId>`, are written, fsynced and
// digest-verified before the entry is committed, and are unlinked only after
// the entry file is gone. Dispatch re-verifies them; a missing or modified file
// blocks the submit and leaves the entry where it is. There is no text-only
// fallback, no second queue and no new `rpcId`.
//
//   queued → submitting → accepted → durable
//   submitting → outcomeUnknown
//   outcomeUnknown → accepted   (read-back found it)
//   outcomeUnknown → queued     (read-back proved it absent)
//
// The store is blocking and serialises every operation on its own monitor; it
// holds no Android object and opens with no engine. Callers run it off the main
// thread. A failure of the write is the answer to "is storage available".
package com.phonedsh.probe.outbox

import java.io.File
import java.io.IOException
import java.util.UUID

internal sealed class SendOutboxException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class InvalidRpcId : SendOutboxException("rpcId is not a lowercase UUIDv4")
    class InvalidSessionId : SendOutboxException("sessionId is invalid")
    class EmptyText : SendOutboxException("text is empty")
    class TextTooLong : SendOutboxException("text exceeds 1000000 characters")
    class UnknownEntry : SendOutboxException("outbox entry does not exist")
    class IllegalTransition(val from: SendOutboxState, val to: SendOutboxState) :
        SendOutboxException("illegal outbox transition ${from.wire} → ${to.wire}")
    class DeleteRequiresDurable(val state: SendOutboxState) :
        SendOutboxException("outbox entry is ${state.wire}, not durable")
    class TooManyAttachments(val count: Int) :
        SendOutboxException("outbox entry has $count attachments (maximum 20)")
    class DuplicateAttachmentId(val id: String) : SendOutboxException("duplicate attachment id $id")
    class InvalidAttachmentId(val id: String) : SendOutboxException("invalid attachment id $id")
    class InvalidContentType : SendOutboxException("attachment contentType is invalid")
    class InvalidFilename : SendOutboxException("attachment filename is invalid")
    class AttachmentMissing(val id: String) : SendOutboxException("attachment bytes missing for $id")
    class AttachmentDigestMismatch(val id: String) :
        SendOutboxException("attachment bytes do not match the recorded digest for $id")
    class AlreadyExists(val rpcId: String) : SendOutboxException("outbox entry already exists for $rpcId")
    class Storage(detail: String, cause: Throwable? = null) :
        SendOutboxException("outbox storage failed: $detail", cause)
}

internal class SendOutbox(
    root: File,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val files: DurableFileStore = DurableFileStore(),
    private val newUuid: () -> String = { UUID.randomUUID().toString() },
) {
    /** `<root>/send-outbox`: one `<rpcId>.json` per entry. */
    val directory: File = File(root, DIRECTORY_NAME)

    /** `<root>/send-outbox/attachments`, in the same durable tree as the entries. */
    val attachmentsDirectory: File = File(directory, "attachments")

    fun attachmentDirectory(rpcId: String): File = File(attachmentsDirectory, rpcId)

    // ------------------------------------------------------------------ enqueue

    /**
     * Creates one `queued` entry and commits it before returning. Throws and
     * writes no entry when the input is invalid or the write fails. [rpcId] is
     * for a caller that already owns the idempotency key (the admission journal's
     * `downstreamId`); enqueueing a key that already has an entry is
     * [SendOutboxException.AlreadyExists] and changes nothing.
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun enqueue(
        sessionId: String,
        text: String,
        attachments: List<SendOutboxAttachmentInput> = emptyList(),
        backend: SendOutboxBackend = SendOutboxBackend.LOCAL,
        rpcId: String? = null,
    ): SendOutboxEntry {
        if (text.isEmpty() && attachments.isEmpty()) throw SendOutboxException.EmptyText()
        if (SendOutboxCodec.characters(text) > SendOutboxCodec.MAX_TEXT_CHARACTERS) {
            throw SendOutboxException.TextTooLong()
        }
        if (!SendOutboxCodec.isValidSessionId(sessionId)) throw SendOutboxException.InvalidSessionId()
        val resolvedRpcId = rpcId ?: newUuid()
        if (!SendOutboxCodec.isValidRpcId(resolvedRpcId)) throw SendOutboxException.InvalidRpcId()
        if (attachments.size > SendOutboxCodec.MAX_ATTACHMENTS) {
            throw SendOutboxException.TooManyAttachments(attachments.size)
        }
        // Enqueue mints a new idempotency key. Reusing one would overwrite its
        // state or its attachment references.
        if (entryFile(resolvedRpcId).exists()) throw SendOutboxException.AlreadyExists(resolvedRpcId)

        val seen = HashSet<String>()
        val metadata = attachments.map { input ->
            val id = input.id ?: newUuid()
            if (!SendOutboxCodec.isValidAttachmentId(id)) throw SendOutboxException.InvalidAttachmentId(id)
            if (!seen.add(id)) throw SendOutboxException.DuplicateAttachmentId(id)
            if (input.contentType.isEmpty() || SendOutboxCodec.characters(input.contentType) > 200) {
                throw SendOutboxException.InvalidContentType()
            }
            if (input.filename.isEmpty() || SendOutboxCodec.characters(input.filename) > 255) {
                throw SendOutboxException.InvalidFilename()
            }
            SendOutboxAttachment(
                id = id,
                kind = input.kind,
                byteSize = input.data.size.toLong(),
                sha256 = SendOutboxCodec.sha256Hex(input.data),
                contentType = input.contentType,
                filename = input.filename,
                storePath = SendOutboxCodec.storePath(resolvedRpcId, id),
            )
        }
        val entry = SendOutboxEntry(
            rpcId = resolvedRpcId,
            sessionId = sessionId,
            text = text,
            createdAtMs = nowMs(),
            state = SendOutboxState.QUEUED,
            attempts = 0,
            backend = backend,
            attachments = metadata.ifEmpty { null },
        )
        // Bytes first, entry second: an entry never references a file that was
        // not written, fsynced and verified. A reported failure removes what
        // this call created; a kill leaves an orphan directory for startup GC.
        try {
            if (metadata.isNotEmpty()) writeAttachmentBytes(metadata, attachments, resolvedRpcId)
            write(entry)
        } catch (failure: SendOutboxException) {
            if (metadata.isNotEmpty()) removeAttachmentDirectory(resolvedRpcId)
            throw failure
        }
        return entry
    }

    // ------------------------------------------------------------------ reading

    /** Every readable entry, ordered by `createdAtMs` then `rpcId`. An unreadable file is skipped, not deleted. */
    @Synchronized
    fun entries(): List<SendOutboxEntry> {
        val names = directory.list() ?: return emptyList()
        return names
            .filter { it.endsWith(SUFFIX) && !it.startsWith(".") }
            .mapNotNull { name -> read(File(directory, name), name.removeSuffix(SUFFIX)) }
            .sortedWith(compareBy<SendOutboxEntry> { it.createdAtMs }.thenBy { it.rpcId })
    }

    @Synchronized
    fun entry(rpcId: String): SendOutboxEntry? {
        if (!SendOutboxCodec.isValidRpcId(rpcId)) return null
        return read(entryFile(rpcId), rpcId)
    }

    /** True when `<rpcId>.json` exists, whether or not it is a readable entry. */
    @Synchronized
    fun hasEntryFile(rpcId: String): Boolean = SendOutboxCodec.isValidRpcId(rpcId) && entryFile(rpcId).exists()

    /**
     * The entries a startup scan or a drain must look at, oldest first; with a
     * [sessionId] this is that session's FIFO. `durable` is never returned: that
     * state only exists until the file is deleted.
     */
    @Synchronized
    fun pending(sessionId: String? = null): List<SendOutboxEntry> =
        entries().filter { it.state != SendOutboxState.DURABLE && (sessionId == null || it.sessionId == sessionId) }

    // -------------------------------------------------------------- attachments

    /**
     * Re-reads every attachment of the entry and checks size and SHA-256. Call it
     * immediately before the first submit and before every retry; when it throws,
     * do not submit, do not send text alone, and record the failure with
     * [recordAttachmentFailure].
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun verifiedAttachmentData(rpcId: String): List<SendOutboxLoadedAttachment> {
        val entry = entry(rpcId) ?: throw SendOutboxException.UnknownEntry()
        return entry.attachments.orEmpty().map { attachment ->
            val file = File(directory, attachment.storePath)
            if (!file.isFile) throw SendOutboxException.AttachmentMissing(attachment.id)
            val data = try {
                file.readBytes()
            } catch (_: IOException) {
                throw SendOutboxException.AttachmentMissing(attachment.id)
            }
            if (data.size.toLong() != attachment.byteSize || SendOutboxCodec.sha256Hex(data) != attachment.sha256) {
                throw SendOutboxException.AttachmentDigestMismatch(attachment.id)
            }
            SendOutboxLoadedAttachment(attachment, data)
        }
    }

    /**
     * Writes the internal diagnostic without changing the state, the attempts or
     * any file reference. Only `queued` and `outcomeUnknown` entries can be
     * blocked this way; any other state is left untouched.
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun recordAttachmentFailure(rpcId: String, failure: SendOutboxAttachmentFailure) {
        val entry = entry(rpcId) ?: throw SendOutboxException.UnknownEntry()
        if (entry.state != SendOutboxState.QUEUED && entry.state != SendOutboxState.OUTCOME_UNKNOWN) return
        write(entry.copy(lastError = failure.wire))
    }

    /**
     * Startup GC: removes `attachments/<rpcId>/` only when no `<rpcId>.json`
     * exists. A directory whose entry exists is never touched, even when one of
     * its files is missing. Returns the removed names.
     */
    @Synchronized
    fun collectOrphanAttachments(): List<String> {
        val children = attachmentsDirectory.listFiles() ?: return emptyList()
        val removed = ArrayList<String>()
        for (child in children.sortedBy { it.name }) {
            if (!child.isDirectory || child.name.startsWith(".")) continue
            if (File(directory, child.name + SUFFIX).exists()) continue
            if (child.deleteRecursively()) removed.add(child.name)
        }
        if (removed.isNotEmpty()) {
            try {
                files.syncDirectory(attachmentsDirectory)
            } catch (_: IOException) {
                // The directories are gone from this process's view; a lost
                // unlink is found again by the next startup GC.
            }
        }
        return removed
    }

    // -------------------------------------------------------------- transitions

    /** `queued → submitting`, written before the transport is touched. Counts the attempt. */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun markSubmitting(rpcId: String): SendOutboxEntry =
        transition(rpcId, SendOutboxState.SUBMITTING) { it.copy(attempts = it.attempts + 1, lastError = null) }

    /** `submitting → accepted` or `outcomeUnknown → accepted`. A local acknowledgement; it deletes nothing. */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun markAccepted(rpcId: String): SendOutboxEntry =
        transition(rpcId, SendOutboxState.ACCEPTED) {
            it.copy(acceptedAtMs = it.acceptedAtMs ?: nowMs(), lastError = null)
        }

    /** `accepted → durable`. */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun markDurable(rpcId: String): SendOutboxEntry =
        transition(rpcId, SendOutboxState.DURABLE) { it.copy(durableAtMs = nowMs()) }

    /** `submitting → outcomeUnknown`: the request may have been written. Never followed by a resend. */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun markOutcomeUnknown(rpcId: String, lastError: String): SendOutboxEntry =
        transition(rpcId, SendOutboxState.OUTCOME_UNKNOWN) {
            it.copy(lastError = truncate(lastError), outcomeUnknownAtMs = nowMs())
        }

    /**
     * `outcomeUnknown → queued`. Only after [SendOutboxReadBack.ABSENT]: the
     * same `rpcId` may then be submitted again.
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun requeue(rpcId: String): SendOutboxEntry =
        transition(rpcId, SendOutboxState.QUEUED) { it.copy(lastError = null, outcomeUnknownAtMs = null) }

    /**
     * Authoritative history holds a user message whose `source.rpcId` is [rpcId].
     * A `submitting` or `outcomeUnknown` entry is first advanced to `accepted`
     * (the history is the proof that the request landed), then `durable`, then
     * deleted. A `durable` entry left by a kill is deleted. Returns true when the
     * entry file was removed; false when there is no such entry or it is still
     * `queued`, which no submit of this store has produced.
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun observeAuthoritativeUserMessage(rpcId: String): Boolean {
        var entry = entry(rpcId) ?: return false
        if (entry.state == SendOutboxState.SUBMITTING || entry.state == SendOutboxState.OUTCOME_UNKNOWN) {
            entry = markAccepted(rpcId)
        }
        if (entry.state == SendOutboxState.ACCEPTED) {
            entry = markDurable(rpcId)
        }
        if (entry.state != SendOutboxState.DURABLE) return false
        return deleteIfDurable(rpcId)
    }

    /**
     * Deletes a `durable` entry: the entry file first, then its attachment
     * directory. Any other state is [SendOutboxException.DeleteRequiresDurable].
     * A failed unlink of the bytes leaves an orphan for [collectOrphanAttachments].
     */
    @Synchronized
    @Throws(SendOutboxException::class)
    fun deleteIfDurable(rpcId: String): Boolean {
        val entry = entry(rpcId) ?: return false
        if (entry.state != SendOutboxState.DURABLE) throw SendOutboxException.DeleteRequiresDurable(entry.state)
        try {
            files.deleteDurably(entryFile(rpcId))
        } catch (failure: IOException) {
            throw SendOutboxException.Storage(failure.message ?: "delete failed", failure)
        }
        removeAttachmentDirectory(rpcId)
        return true
    }

    private fun transition(
        rpcId: String,
        next: SendOutboxState,
        change: (SendOutboxEntry) -> SendOutboxEntry,
    ): SendOutboxEntry {
        val entry = entry(rpcId) ?: throw SendOutboxException.UnknownEntry()
        if (entry.state == next && next != SendOutboxState.SUBMITTING) {
            // The live event and the send acknowledgement can both report the
            // same fact; the second report is not an edge.
            return entry
        }
        if (!SendOutboxTransition.allows(entry.state, next)) {
            throw SendOutboxException.IllegalTransition(entry.state, next)
        }
        val updated = change(entry.copy(state = next))
        write(updated)
        return updated
    }

    // ------------------------------------------------------------------ storage

    private fun entryFile(rpcId: String): File = File(directory, rpcId + SUFFIX)

    /** A file that is not a valid entry, or whose name is not its own `rpcId`, is not an entry. */
    private fun read(file: File, expectedRpcId: String): SendOutboxEntry? {
        val text = try {
            if (!file.isFile) return null
            file.readText(Charsets.UTF_8)
        } catch (_: IOException) {
            return null
        }
        val entry = try {
            SendOutboxCodec.decode(text)
        } catch (_: SendOutboxInvalidEntryException) {
            return null
        }
        return entry.takeIf { it.rpcId == expectedRpcId }
    }

    private fun write(entry: SendOutboxEntry) {
        val bytes = try {
            SendOutboxCodec.encode(entry).toByteArray(Charsets.UTF_8)
        } catch (failure: SendOutboxInvalidEntryException) {
            throw SendOutboxException.Storage(failure.message ?: "entry is invalid", failure)
        }
        try {
            files.writeAtomically(entryFile(entry.rpcId), bytes)
        } catch (failure: IOException) {
            throw SendOutboxException.Storage(failure.message ?: "write failed", failure)
        }
    }

    private fun writeAttachmentBytes(
        metadata: List<SendOutboxAttachment>,
        inputs: List<SendOutboxAttachmentInput>,
        rpcId: String,
    ) {
        try {
            val rpcDirectory = attachmentDirectory(rpcId)
            files.createDirectories(rpcDirectory)
            // Publish `attachments/<rpcId>` before a file inside it becomes the
            // only copy of a byte.
            files.syncDirectory(attachmentsDirectory)
            for ((attachment, input) in metadata.zip(inputs)) {
                val file = File(rpcDirectory, attachment.id)
                files.writeAtomically(file, input.data)
                val readBack = try {
                    file.readBytes()
                } catch (_: IOException) {
                    throw SendOutboxException.AttachmentMissing(attachment.id)
                }
                if (readBack.size != input.data.size || SendOutboxCodec.sha256Hex(readBack) != attachment.sha256) {
                    throw SendOutboxException.AttachmentDigestMismatch(attachment.id)
                }
            }
        } catch (failure: IOException) {
            throw SendOutboxException.Storage(failure.message ?: "attachment write failed", failure)
        }
    }

    private fun removeAttachmentDirectory(rpcId: String) {
        val rpcDirectory = attachmentDirectory(rpcId)
        if (!rpcDirectory.exists()) return
        rpcDirectory.deleteRecursively()
        try {
            files.syncDirectory(attachmentsDirectory)
        } catch (_: IOException) {
            // Left for the next startup GC.
        }
    }

    private fun truncate(value: String): String {
        val limit = SendOutboxCodec.MAX_LAST_ERROR_CHARACTERS
        if (SendOutboxCodec.characters(value) <= limit) return value
        return value.substring(0, value.offsetByCodePoints(0, limit))
    }

    companion object {
        const val DIRECTORY_NAME: String = "send-outbox"
        private const val SUFFIX: String = ".json"
    }
}
