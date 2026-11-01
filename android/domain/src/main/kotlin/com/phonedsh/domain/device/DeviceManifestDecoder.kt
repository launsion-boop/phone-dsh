// The tolerant decoder of pdsh-device-caps/1 documents.
// SPDX-License-Identifier: MIT
//
// Hand-written like the encoder next door: :domain adds no JSON dependency for
// one document, and `org.json` is an Android stub on the host JVM, where this
// module runs its whole suite with `unitTests.isReturnDefaultValues = false`.
// The reader is a recursive-descent RFC 8259 parser that keeps a nesting bound;
// the validation below it is the schema's rules, not a copy of a JSON library's.
//
// `DeviceManifest.parse`'s KDoc owns the important asymmetry: the schema's root
// `additionalProperties: false` binds what this host writes, while host/v1
// README §2 D5 requires the reading side to accept any legal JSON, so unknown
// members are ignored here. Unknown members are never errors; known members
// always are when their type or value is wrong.

package com.phonedsh.domain.device

import java.math.BigDecimal

/** The reader and validator behind [DeviceManifest.parse] and [DeviceManifest.parseOrNull]. */
internal object DeviceManifestDecoder {
    /** The schema's `protocol.id` maximum length. */
    private const val PROTOCOL_ID_MAX_LENGTH = 128

    /** How deeply a document may nest before it is refused as malformed. */
    private const val NESTING_LIMIT = 64

    /** Decodes one `pdsh-device-caps/1` document. */
    fun decode(text: String): DeviceManifest {
        val document = Reader(text).readDocument()
        val root = document as? Node.Obj
            ?: fail(
                DeviceManifestFailure.ROOT_NOT_OBJECT,
                "the document root must be an object, was ${document.describe()}",
            )

        val schema = root.requiredString("schema")
        if (schema != DeviceManifest.SCHEMA) {
            outOfRange("schema", "the const \"${DeviceManifest.SCHEMA}\"", "\"$schema\"")
        }
        val deviceId = root.requiredString("device_id")
        if (!DeviceManifest.DEVICE_ID_PATTERN.matches(deviceId)) {
            outOfRange(
                "device_id",
                "a match of ${DeviceManifest.DEVICE_ID_PATTERN}",
                "\"$deviceId\"",
            )
        }

        return DeviceManifest(
            deviceId = deviceId,
            protocol = decodeProtocol(root.requiredObject("protocol")),
            capabilities = decodeCapabilities(root.requiredObject("capabilities")),
            limits = decodeLimits(root.requiredObject("limits")),
            auth = decodeAuth(root.requiredObject("auth")),
        )
    }

    /**
     * Decodes [text], or returns `null` when it is not JSON at all.
     *
     * Only [DeviceManifestFailure.MALFORMED_JSON] becomes `null`: an empty
     * string, a fragment, a document with trailing bytes. A well-formed JSON
     * document that is missing a required member or carries a forbidden value
     * still throws, because that document is broken, not absent.
     */
    fun decodeOrNull(text: String): DeviceManifest? =
        try {
            decode(text)
        } catch (failure: DeviceManifestException) {
            if (failure.failure != DeviceManifestFailure.MALFORMED_JSON) throw failure
            null
        }

    private fun decodeProtocol(node: Node.Obj): DeviceProtocol {
        val id = node.requiredString("id", "protocol.id")
        if (id.isEmpty() || id.length > PROTOCOL_ID_MAX_LENGTH) {
            outOfRange(
                "protocol.id",
                "a string of 1..$PROTOCOL_ID_MAX_LENGTH characters",
                "a ${id.length}-character string",
            )
        }
        val version = node.requiredString("version", "protocol.version")
        if (!DeviceProtocol.VERSION_PATTERN.matches(version)) {
            outOfRange(
                "protocol.version",
                "a MAJOR.MINOR match of ${DeviceProtocol.VERSION_PATTERN}",
                "\"$version\"",
            )
        }
        return DeviceProtocol(id, version)
    }

    private fun decodeCapabilities(node: Node.Obj): Map<String, CapabilityValue> {
        val decoded = LinkedHashMap<String, CapabilityValue>(node.members.size)
        node.members.forEach { (name, value) ->
            decodeCapability(name, value)?.let { decoded[name] = it }
        }
        return decoded
    }

    /**
     * Decodes one capability, or returns `null` when the name is not declared
     * by the schema.
     *
     * A vocabulary entry keeps exactly the members the schema declares for it;
     * a `vehicle.<name>` or `vendor.<name>.*` value is passed through whole.
     * An unknown name is dropped without inspecting its value: the schema
     * allows additional capability names and defines "not declared" as
     * unavailable, so there is no shape here to validate against.
     */
    private fun decodeCapability(name: String, value: Node): CapabilityValue? {
        val path = "capabilities.$name"
        return when {
            DeviceCapability.isVendorExtension(name) -> passThrough(path, value.asObject(path))
            DeviceCapability.isVehicle(name) -> {
                val node = value.asObject(path)
                // The schema's vehicle.* value requires granted_by; vehicle
                // access exists only when the vendor granted it (§4.5). The
                // model also refuses a blank grant, so the decoder must report
                // it as a manifest failure rather than let the constructor throw.
                val grantedBy = node.requiredString("granted_by", "$path.granted_by")
                if (grantedBy.isBlank()) {
                    outOfRange("$path.granted_by", "a non-blank string", "\"$grantedBy\"")
                }
                passThrough(path, node)
            }

            else -> {
                val declared = DeviceCapability.exact(name) ?: return null
                val node = value.asObject(path)
                declared.required.forEach { member ->
                    if (!node.members.containsKey(member)) {
                        fail(
                            DeviceManifestFailure.MISSING_MEMBER,
                            "$path.$member is required by the schema",
                        )
                    }
                }
                val kept = LinkedHashMap<String, Any>(node.members.size)
                node.members.forEach { (member, memberValue) ->
                    if (member in declared.members) {
                        kept[member] = memberValue.flatValue("$path.$member")
                    }
                }
                CapabilityValue.ofMembers(kept)
            }
        }
    }

    /** Converts a pass-through object member by member, nested objects included. */
    private fun passThrough(path: String, node: Node.Obj): CapabilityValue {
        val values = LinkedHashMap<String, Any>(node.members.size)
        node.members.forEach { (name, value) -> values[name] = value.jsonValue("$path.$name") }
        return try {
            CapabilityValue.passThrough(values)
        } catch (rejected: IllegalArgumentException) {
            fail(
                DeviceManifestFailure.WRONG_TYPE,
                "$path cannot be represented as a capability value: ${rejected.message}",
            )
        }
    }

    private fun decodeLimits(node: Node.Obj): DeviceLimits {
        val maxFrameBytes = node.requiredInteger("max_frame_bytes", "limits.max_frame_bytes")
        if (maxFrameBytes !in 1L..DeviceLimits.MAX_FRAME_BYTES.toLong()) {
            outOfRange(
                "limits.max_frame_bytes",
                "an integer in 1..${DeviceLimits.MAX_FRAME_BYTES}",
                maxFrameBytes.toString(),
            )
        }
        val textBytes = node.optionalInteger("text_bytes", "limits.text_bytes")
            ?.positiveInt("limits.text_bytes")
        val audioKbps = node.optionalInteger("audio_kbps", "limits.audio_kbps")
            ?.positiveInt("limits.audio_kbps")
        return DeviceLimits(maxFrameBytes.toInt(), textBytes, audioKbps)
    }

    private fun decodeAuth(node: Node.Obj): DeviceAuth {
        val pairingName = node.requiredString("pairing", "auth.pairing")
        val pairing = DeviceAuth.Pairing.entries.firstOrNull { it.wireName == pairingName }
            ?: outOfRange(
                "auth.pairing",
                "one of " + DeviceAuth.Pairing.entries.joinToString(", ") { "\"${it.wireName}\"" },
                "\"$pairingName\"",
            )
        val replay = node.requiredString("replay", "auth.replay")
        if (replay != DeviceAuth.REPLAY_COUNTER_TTL) {
            outOfRange(
                "auth.replay",
                "the const \"${DeviceAuth.REPLAY_COUNTER_TTL}\"",
                "\"$replay\"",
            )
        }
        return DeviceAuth(pairing, replay)
    }

    private fun Node.asObject(path: String): Node.Obj =
        this as? Node.Obj ?: wrongType(path, "an object", this)

    private fun Node.Obj.required(name: String, path: String = name): Node =
        members[name] ?: fail(
            DeviceManifestFailure.MISSING_MEMBER,
            "$path is required by the schema",
        )

    private fun Node.Obj.requiredString(name: String, path: String = name): String {
        val node = required(name, path)
        return (node as? Node.Str)?.value ?: wrongType(path, "a string", node)
    }

    private fun Node.Obj.requiredObject(name: String, path: String = name): Node.Obj {
        val node = required(name, path)
        return node as? Node.Obj ?: wrongType(path, "an object", node)
    }

    private fun Node.Obj.requiredInteger(name: String, path: String = name): Long {
        val node = required(name, path)
        return node.integerOrNull() ?: wrongType(path, "an integer", node)
    }

    private fun Node.Obj.optionalInteger(name: String, path: String = name): Long? {
        val node = members[name] ?: return null
        return node.integerOrNull() ?: wrongType(path, "an integer", node)
    }

    private fun Node.integerOrNull(): Long? = when (this) {
        is Node.Num -> integralValue(raw)
        else -> null
    }

    /**
     * The integer a JSON number denotes, or `null` when it denotes none.
     *
     * JSON Schema treats `1`, `1.0` and `1e3` as the same integer, so the
     * exponent/fraction forms are accepted when the value is exact; `1.5` and
     * a value beyond `Long` are not integers the model can hold.
     */
    private fun integralValue(raw: String): Long? = try {
        if (raw.contains('.') || raw.contains('e') || raw.contains('E')) {
            BigDecimal(raw).longValueExact()
        } else {
            raw.toLongOrNull()
        }
    } catch (_: ArithmeticException) {
        null
    } catch (_: NumberFormatException) {
        null
    }

    private fun Long.positiveInt(path: String): Int {
        if (this < 1L) outOfRange(path, "an integer >= 1", toString())
        if (this > Int.MAX_VALUE.toLong()) outOfRange(path, "an integer <= ${Int.MAX_VALUE}", toString())
        return toInt()
    }

    /** A JSON scalar, or a flat list of scalars (the shape a vocabulary entry keeps). */
    private fun Node.flatValue(path: String): Any = when (this) {
        is Node.Str -> value
        is Node.Num -> integerValue(path)
        is Node.Bool -> value
        is Node.Arr -> elements.mapIndexed { index, element -> element.flatScalar("$path[$index]") }
        is Node.Obj, Node.Null -> wrongType(path, "a scalar or a list of scalars", this)
    }

    private fun Node.flatScalar(path: String): Any = when (this) {
        is Node.Str -> value
        is Node.Num -> integerValue(path)
        is Node.Bool -> value
        is Node.Obj, is Node.Arr, Node.Null -> wrongType(path, "a scalar", this)
    }

    private fun Node.Num.integerValue(path: String): Any {
        val integer = integralValue(raw) ?: wrongType(path, "an integer", this)
        return if (integer in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) integer.toInt() else integer
    }

    /** A pass-through JSON value: scalars, arrays and objects, recursively. */
    private fun Node.jsonValue(path: String): Any = when (this) {
        is Node.Str -> value
        is Node.Num -> integerValue(path)
        is Node.Bool -> value
        is Node.Arr -> elements.mapIndexed { index, element -> element.jsonValue("$path[$index]") }
        is Node.Obj -> {
            val members = LinkedHashMap<String, Any>(this.members.size)
            this.members.forEach { (name, element) ->
                members[name] = element.jsonValue("$path.$name")
            }
            members
        }

        Node.Null -> wrongType(path, "a JSON value other than null", this)
    }

    private fun Node.describe(): String = when (this) {
        is Node.Obj -> "an object"
        is Node.Arr -> "an array"
        is Node.Str -> "a string"
        is Node.Num -> "the number $raw"
        is Node.Bool -> "a boolean"
        Node.Null -> "null"
    }

    private fun fail(failure: DeviceManifestFailure, detail: String): Nothing =
        throw DeviceManifestException(failure, detail)

    private fun wrongType(path: String, expected: String, actual: Node): Nothing =
        fail(DeviceManifestFailure.WRONG_TYPE, "$path must be $expected, was ${actual.describe()}")

    private fun outOfRange(path: String, expected: String, actual: String): Nothing =
        fail(DeviceManifestFailure.OUT_OF_RANGE, "$path must be $expected, was $actual")

    /** One JSON value, kept structural so the schema check can name the path that failed. */
    private sealed interface Node {
        class Obj(val members: Map<String, Node>) : Node
        class Arr(val elements: List<Node>) : Node
        class Str(val value: String) : Node
        class Num(val raw: String) : Node
        class Bool(val value: Boolean) : Node
        data object Null : Node
    }

    /** Recursive-descent RFC 8259 reader with no trailing-garbage tolerance. */
    private class Reader(private val text: String) {
        private var index: Int = 0

        fun readDocument(): Node {
            val node = readValue(0)
            skipWhitespace()
            if (index != text.length) malformed("trailing content at offset $index")
            return node
        }

        private fun readValue(depth: Int): Node {
            if (depth > NESTING_LIMIT) malformed("nesting is deeper than $NESTING_LIMIT levels")
            skipWhitespace()
            if (index >= text.length) malformed("unexpected end of document")
            return when (val character = text[index]) {
                '{' -> readObject(depth)
                '[' -> readArray(depth)
                '"' -> Node.Str(readString())
                't' -> {
                    expectKeyword("true")
                    Node.Bool(true)
                }

                'f' -> {
                    expectKeyword("false")
                    Node.Bool(false)
                }

                'n' -> {
                    expectKeyword("null")
                    Node.Null
                }

                else -> if (character == '-' || character in '0'..'9') {
                    Node.Num(readNumber())
                } else {
                    malformed("unexpected character '$character' at offset $index")
                }
            }
        }

        private fun readObject(depth: Int): Node.Obj {
            expect('{')
            val members = LinkedHashMap<String, Node>()
            skipWhitespace()
            if (index < text.length && text[index] == '}') {
                index++
                return Node.Obj(members)
            }
            while (true) {
                skipWhitespace()
                if (index >= text.length || text[index] != '"') {
                    malformed("expected a member name at offset $index")
                }
                val name = readString()
                expect(':')
                // D5's canonical form has no duplicate names. A non-canonical
                // document that repeats one keeps the last value; D5 guarantees
                // this host's own peers never send such a document.
                members[name] = readValue(depth + 1)
                skipWhitespace()
                if (index >= text.length) malformed("unterminated object")
                when (text[index]) {
                    ',' -> {
                        index++
                        skipWhitespace()
                        if (index < text.length && text[index] == '}') {
                            malformed("trailing comma at offset $index")
                        }
                    }

                    '}' -> {
                        index++
                        return Node.Obj(members)
                    }

                    else -> malformed("expected ',' or '}' at offset $index")
                }
            }
        }

        private fun readArray(depth: Int): Node.Arr {
            expect('[')
            val elements = ArrayList<Node>()
            skipWhitespace()
            if (index < text.length && text[index] == ']') {
                index++
                return Node.Arr(elements)
            }
            while (true) {
                elements.add(readValue(depth + 1))
                skipWhitespace()
                if (index >= text.length) malformed("unterminated array")
                when (text[index]) {
                    ',' -> {
                        index++
                        skipWhitespace()
                        if (index < text.length && text[index] == ']') {
                            malformed("trailing comma at offset $index")
                        }
                    }

                    ']' -> {
                        index++
                        return Node.Arr(elements)
                    }

                    else -> malformed("expected ',' or ']' at offset $index")
                }
            }
        }

        private fun readString(): String {
            expect('"')
            val builder = StringBuilder()
            while (true) {
                if (index >= text.length) malformed("unterminated string")
                val character = text[index++]
                when (character) {
                    '"' -> return builder.toString()
                    '\\' -> {
                        if (index >= text.length) malformed("unterminated escape")
                        when (val escaped = text[index++]) {
                            '"', '\\', '/' -> builder.append(escaped)
                            'b' -> builder.append('\b')
                            'f' -> builder.append('\u000C')
                            'n' -> builder.append('\n')
                            'r' -> builder.append('\r')
                            't' -> builder.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) malformed("truncated unicode escape")
                                val hex = text.substring(index, index + 4)
                                if (!hex.all { it.isHexDigit() }) {
                                    malformed("bad unicode escape '\\u$hex'")
                                }
                                index += 4
                                builder.append(hex.toInt(16).toChar())
                            }

                            else -> malformed("bad escape '\\$escaped'")
                        }
                    }

                    else -> {
                        if (character < ' ') {
                            malformed("unescaped control character in a string at offset ${index - 1}")
                        }
                        builder.append(character)
                    }
                }
            }
        }

        private fun readNumber(): String {
            val start = index
            if (index < text.length && text[index] == '-') index++
            if (index < text.length && text[index] == '0') {
                index++
            } else {
                readDigits(required = true)
            }
            if (index < text.length && text[index] == '.') {
                index++
                readDigits(required = true)
            }
            if (index < text.length && (text[index] == 'e' || text[index] == 'E')) {
                index++
                if (index < text.length && (text[index] == '+' || text[index] == '-')) index++
                readDigits(required = true)
            }
            return text.substring(start, index)
        }

        private fun readDigits(required: Boolean) {
            val start = index
            while (index < text.length && text[index] in '0'..'9') index++
            if (required && index == start) malformed("expected a digit at offset $index")
        }

        private fun expectKeyword(keyword: String) {
            if (!text.startsWith(keyword, index)) malformed("expected '$keyword' at offset $index")
            index += keyword.length
        }

        private fun expect(character: Char) {
            skipWhitespace()
            if (index >= text.length || text[index] != character) {
                malformed("expected '$character' at offset $index")
            }
            index++
        }

        private fun skipWhitespace() {
            while (index < text.length && text[index].isJsonWhitespace()) index++
        }

        private fun Char.isJsonWhitespace(): Boolean =
            this == ' ' || this == '\t' || this == '\n' || this == '\r'

        private fun Char.isHexDigit(): Boolean =
            this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

        private fun malformed(detail: String): Nothing =
            throw DeviceManifestException(DeviceManifestFailure.MALFORMED_JSON, detail)
    }
}
