// manifest.json of wal.md §7: the checkpoint, its canonical form and its schema.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.wire.NativeWal
import com.phonedsh.wire.WalException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * One `segments[]` entry of `manifest.json` (`wal.md` §7).
 *
 * [file] is the manifest-form name (`wal/<epoch:08d>.<segment:06d>.xlwal`),
 * [firstMseq] equals the segment header's `first_mseq` and [lastMseq] is the
 * highest **mutation** mseq in the segment, 0 when the segment holds none (the
 * idle epoch-close segment of `golden/wal/segment-epoch-only.json`).
 *
 * @property file the relative segment name.
 * @property epoch the segment's epoch number, at least 1.
 * @property firstMseq the header's `first_mseq`.
 * @property lastMseq the highest mutation mseq, or 0.
 */
data class ManifestSegment(
    val file: String,
    val epoch: Int,
    val firstMseq: Long,
    val lastMseq: Long,
) {
    /** The parsed segment name; a manifest entry is validated before this runs. */
    val name: WalSegmentName
        get() = WalSegmentName.require(file)

    companion object {
        /** The manifest view of [name] with its real header and mutation range. */
        fun of(name: WalSegmentName, firstMseq: Long, lastMseq: Long): ManifestSegment =
            ManifestSegment(
                file = name.manifestFile,
                epoch = name.epoch,
                firstMseq = firstMseq,
                lastMseq = lastMseq,
            )
    }
}

/**
 * The `manifest.json` checkpoint of `wal.md` §7 (D11, D17).
 *
 * Fields: `format` 1, the 32-hex `boot_id`, the strictly contiguous
 * `materialized_upto_mseq` watermark, the never-reused `last_mseq`
 * high-water mark, `last_durable_epoch` and the retained [segments].
 *
 * The four fields the roadmap names — [lastMseq], [segments],
 * [lastDurableEpoch], [bootId] — come first; [materializedUptoMseq] and
 * [format] carry defaults so a checkpoint that only needs the named four can be
 * written without repeating the proto-1 constants. A write always carries the
 * real watermark: it is the one field that ties the log to the applied copy.
 *
 * ### Schema versus corruption
 *
 * [parse] treats `wal.md` §7.2's revised definition literally: a manifest is
 * **schema-invalid** (`WAL_MANIFEST_INVALID`, which recovery routes to the
 * missing-manifest rule) when a **required member is missing** or a **known
 * member is out of range** — `format` other than 1, a `boot_id` that is not 32
 * lowercase hex, a negative or over-wide integer, `last_durable_epoch` above
 * 99999999, a `segments[].epoch` outside `1..99999999`, `first_mseq` below 1 or
 * a `file` that is not the fixed-width name. An **unknown member is ignored**
 * (README §2). A file that is schema-valid but semantically impossible — a
 * watermark above `last_mseq`, an overlapping segment range, a `file` whose
 * epoch disagrees with its `epoch` member — is `WAL_CORRUPT`, not a missing
 * manifest, because no rewrite of a truncated checkpoint can be inferred from
 * it.
 *
 * @property lastMseq the highest mseq ever allocated and accepted at level 1
 *   (D17); truncation never lowers it.
 * @property segments the retained segments, in `<epoch,segment>` order.
 * @property lastDurableEpoch the epoch of the most recently closed (level-2
 *   durable) epoch; 0 when no epoch has closed.
 * @property bootId the boot that wrote this manifest.
 * @property materializedUptoMseq the strictly contiguous applied watermark.
 * @property format the only proto-1 value, 1.
 */
data class Manifest(
    val lastMseq: Long,
    val segments: List<ManifestSegment>,
    val lastDurableEpoch: Int,
    val bootId: BootId,
    val materializedUptoMseq: Long = 0L,
    val format: Int = FORMAT,
) {
    /** The segments in `<epoch,segment>` order, the order §7 requires. */
    fun sortedSegments(): List<ManifestSegment> =
        segments.sortedWith(compareBy({ it.epoch }, { it.file }))

    /** The highest epoch any listed segment names, or 0. */
    fun highestListedEpoch(): Int = segments.maxOfOrNull { it.epoch } ?: 0

    /**
     * The canonical JSON text of §7.1.
     *
     * Member order is sorted (D5's canonical form); the Rust writer re-encodes
     * it on [encode], so the bytes on disk are exactly what
     * `pdsh_wal::Manifest::to_json` produces and a round trip is byte-stable.
     * Unknown members never survive a write because this object has none.
     */
    fun toJson(): String {
        val members = sortedMapOf<String, JsonValue>()
        members["boot_id"] = JsonString(bootId.hex)
        members["format"] = JsonNumber(format.toString())
        members["last_durable_epoch"] = JsonNumber(lastDurableEpoch.toString())
        members["last_mseq"] = JsonNumber(lastMseq.toString())
        members["materialized_upto_mseq"] = JsonNumber(materializedUptoMseq.toString())
        val segmentValues = sortedSegments().map { segment ->
            val entry = sortedMapOf<String, JsonValue>()
            entry["epoch"] = JsonNumber(segment.epoch.toString())
            entry["file"] = JsonString(segment.file)
            entry["first_mseq"] = JsonNumber(segment.firstMseq.toString())
            entry["last_mseq"] = JsonNumber(segment.lastMseq.toString())
            JsonObject(entry)
        }
        members["segments"] = JsonArray(segmentValues)
        return JsonObject(members).toJsonString()
    }

    /**
     * The canonical `manifest.json` bytes (`wal.md` §7.1).
     *
     * The encoder is the Rust writer: it validates like [parse] and ignores
     * unknown members, so the file this returns is the one the kernel would
     * emit for the same checkpoint.
     *
     * @throws WalException `WAL_MANIFEST_INVALID` or `WAL_CORRUPT` when this
     *   object is not a valid checkpoint (a programmatic construction is not
     *   trusted either).
     */
    fun encode(): ByteArray = NativeWal.emitManifest(toJson())

    companion object {
        /** The only `format` of proto 1. */
        const val FORMAT: Int = 1

        /** The largest `last_durable_epoch` / `segments[].epoch` the schema allows. */
        const val MAX_EPOCH: Int = WalSegmentName.MAX_EPOCH

        /** A brand-new workspace's checkpoint: everything at 0, no segments. */
        fun forNewWorkspace(bootId: BootId): Manifest =
            Manifest(
                lastMseq = 0,
                segments = emptyList(),
                lastDurableEpoch = 0,
                bootId = bootId,
                materializedUptoMseq = 0,
            )

        /**
         * Parses and validates `manifest.json` bytes.
         *
         * @throws WalException `WAL_MANIFEST_INVALID` for the schema-invalid
         *   cases of §7.2 (missing required member, out-of-range known member);
         *   `WAL_CORRUPT` for a schema-valid but impossible checkpoint.
         * @throws com.phonedsh.wire.WireUnavailable when the native kernel is
         *   absent.
         */
        fun parse(bytes: ByteArray): Manifest {
            val text = decodeUtf8(bytes)
            val value = try {
                JsonValue.parse(text)
            } catch (error: RuntimeException) {
                throw invalid("manifest.json is not JSON: ${error.message}")
            }
            val objectValue = value as? JsonObject ?: throw invalid("manifest.json is not an object")

            val format = uint(objectValue, "format", 0L, Long.MAX_VALUE)
            if (format != FORMAT.toLong()) {
                throw invalid("format $format is not $FORMAT")
            }
            val bootIdHex = string(objectValue, "boot_id")
            if (!BOOT_ID_PATTERN.matches(bootIdHex)) {
                throw invalid("boot_id is not 32 lowercase hex characters")
            }
            val materializedUpto = uint(objectValue, "materialized_upto_mseq", 0L, Long.MAX_VALUE)
            val lastMseq = uint(objectValue, "last_mseq", 0L, Long.MAX_VALUE)
            val lastDurableEpoch = uint(objectValue, "last_durable_epoch", 0L, MAX_EPOCH.toLong())
            val segmentsValue = required(objectValue, "segments")
            val segmentsArray = segmentsValue as? JsonArray
                ?: throw invalid("segments is not an array")
            val segments = segmentsArray.values.mapIndexed { index, entry ->
                manifestSegment(entry, index)
            }

            // The Rust parser is the second gate: it validates the same schema
            // with the wire's own reader and classifies an impossible
            // checkpoint as WAL_CORRUPT. The bytes go in unchanged so an
            // unknown member is ignored by the kernel too (README §2).
            NativeWal.parseManifest(bytes)

            return Manifest(
                lastMseq = lastMseq,
                segments = segments,
                lastDurableEpoch = lastDurableEpoch.toInt(),
                bootId = BootId(bootIdHex),
                materializedUptoMseq = materializedUpto,
                format = format.toInt(),
            )
        }

        /** Parses a `manifest.json` text form. */
        fun fromJson(text: String): Manifest = parse(text.toByteArray(Charsets.UTF_8))

        private val BOOT_ID_PATTERN = Regex("^[0-9a-f]{32}$")
        private val SEGMENT_FILE_PATTERN =
            Regex("^wal/[0-9]{${WalSegmentName.EPOCH_DIGITS}}\\.[0-9]{${WalSegmentName.SEGMENT_DIGITS}}\\.${WalSegmentName.EXTENSION}$")

        private fun manifestSegment(value: JsonValue, index: Int): ManifestSegment {
            val context = "segments[$index]"
            val objectValue = value as? JsonObject
                ?: throw invalid("$context is not an object")
            val file = string(objectValue, "file", context)
            if (!SEGMENT_FILE_PATTERN.matches(file)) {
                throw invalid("$context file is not wal/<epoch:08d>.<segment:06d>.xlwal")
            }
            val epoch = uint(objectValue, "epoch", 1L, MAX_EPOCH.toLong(), context)
            val firstMseq = uint(objectValue, "first_mseq", 1L, Long.MAX_VALUE, context)
            val lastMseq = uint(objectValue, "last_mseq", 0L, Long.MAX_VALUE, context)
            return ManifestSegment(
                file = file,
                epoch = epoch.toInt(),
                firstMseq = firstMseq,
                lastMseq = lastMseq,
            )
        }

        private fun required(objectValue: JsonObject, name: String, context: String = "manifest"): JsonValue =
            objectValue[name] ?: throw invalid("$context has no required member \"$name\"")

        private fun string(
            objectValue: JsonObject,
            name: String,
            context: String = "manifest",
        ): String {
            val value = required(objectValue, name, context)
            return (value as? JsonString)?.value
                ?: throw invalid("$context member \"$name\" is not a string")
        }

        private fun uint(
            objectValue: JsonObject,
            name: String,
            minimum: Long,
            maximum: Long,
            context: String = "manifest",
        ): Long {
            val value = required(objectValue, name, context)
            val number = value as? JsonNumber
                ?: throw invalid("$context member \"$name\" is not an integer")
            val asLong = number.asLongOrNull()
                ?: throw invalid("$context member \"$name\" is not an integer in range")
            if (asLong < minimum || asLong > maximum) {
                throw invalid("$context member \"$name\" is out of range: $asLong")
            }
            return asLong
        }

        private fun decodeUtf8(bytes: ByteArray): String {
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            return try {
                decoder.decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: CharacterCodingException) {
                throw invalid("manifest.json is not UTF-8")
            }
        }

        private fun invalid(detail: String): WalException =
            WalException("WAL_MANIFEST_INVALID", detail)
    }
}
