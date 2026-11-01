// The open value object of one device capability.
// SPDX-License-Identifier: MIT
//
// The schema says capability value objects are open ("extra members are ignored
// because they carry protocol-specific detail"), so this type keeps a small,
// ordered, JSON-safe member map instead of fifteen typed classes. The members
// the host relies on for a standard capability are still checked against the
// schema by `DeviceCapabilitySchemaTest`, which builds one manifest containing
// every vocabulary entry from the schema's own `required` lists.
//
// Two shapes exist on purpose:
//
//  * `of` (public) builds a standard value: scalars and flat lists only. Every
//    member of every vocabulary entry in the schema has that shape, so a nested
//    value there is a caller bug, not protocol detail.
//  * `passThrough` (internal, used by the decoder) keeps `vendor.<name>.*` and
//    `vehicle.<name>` values whole. The schema calls vendor values "passed
//    through unparsed", and they may nest; flattening or rejecting them would
//    break the device's own detail.

package com.phonedsh.domain.device

/**
 * The members of one declared capability, in declaration order.
 *
 * Supported member values are `String`, `Int`, `Long`, `Boolean`, flat lists of
 * those, and — for a pass-through value only — nested string-keyed maps and
 * arrays of any of those. Nested values are reachable through [members]; the
 * typed accessors ([string], [int], [stringList], [intList]) only read the flat
 * shape and return `null` for anything else.
 */
class CapabilityValue private constructor(
    private val orderedMembers: Map<String, Any>,
) {
    /** The members in declaration order. */
    val members: Map<String, Any>
        get() = orderedMembers

    /** The string member [name], or `null` when absent or another type. */
    fun string(name: String): String? = orderedMembers[name] as? String

    /** The integer member [name], or `null` when absent or another type. */
    fun int(name: String): Int? = when (val value = orderedMembers[name]) {
        is Int -> value
        is Long -> value.toInt()
        else -> null
    }

    /** The string-list member [name], or `null` when absent or another type. */
    fun stringList(name: String): List<String>? {
        val value = orderedMembers[name] as? List<*> ?: return null
        if (!value.all { it is String }) return null
        return value.map { it as String }
    }

    /** The integer-list member [name], or `null` when absent or another type. */
    fun intList(name: String): List<Int>? {
        val value = orderedMembers[name] as? List<*> ?: return null
        if (!value.all { it is Int || it is Long }) return null
        return value.map { (it as Number).toInt() }
    }

    override fun toString(): String = "CapabilityValue($orderedMembers)"

    companion object {
        /** Builds a standard value from alternating member names and flat JSON-safe values. */
        fun of(vararg members: Pair<String, Any>): CapabilityValue {
            val ordered = LinkedHashMap<String, Any>(members.size)
            members.forEach { (name, value) ->
                validateName(name)
                require(!ordered.containsKey(name)) { "capability member \"$name\" is declared twice" }
                ordered[name] = value
            }
            return ofMembers(ordered)
        }

        /** Builds a standard value from an already-collected member map, flat members only. */
        internal fun ofMembers(members: Map<String, Any>): CapabilityValue {
            val ordered = LinkedHashMap<String, Any>(members.size)
            members.forEach { (name, value) ->
                validateName(name)
                require(isFlat(value)) {
                    "capability member \"$name\" has an unsupported value type " +
                        "${value::class.simpleName}: a standard capability keeps flat values only"
                }
                ordered[name] = value
            }
            return CapabilityValue(ordered)
        }

        /**
         * Builds a pass-through value: the schema says `vendor.<name>.*` is
         * "passed through unparsed", so nested objects and arrays survive
         * exactly as the device sent them.
         *
         * The leaves are still the model's JSON-safe scalars ([String], [Int],
         * [Long], [Boolean]) and nested combinations of them. A JSON null or a
         * fractional number has no representation in this type and is refused by
         * the decoder rather than coerced or dropped.
         */
        internal fun passThrough(members: Map<String, Any>): CapabilityValue {
            val ordered = LinkedHashMap<String, Any>(members.size)
            members.forEach { (name, value) ->
                validateName(name)
                require(isJsonSafe(value)) {
                    "capability member \"$name\" has a value that is not JSON-safe: " +
                        "${value::class.simpleName}"
                }
                ordered[name] = value
            }
            return CapabilityValue(ordered)
        }

        private fun validateName(name: String) {
            require(name.isNotEmpty()) { "a capability member needs a non-empty name" }
            require(name.none { it.isWhitespace() || it.isISOControl() }) {
                "capability member \"$name\" must not contain whitespace or control characters"
            }
        }

        private fun isFlat(value: Any): Boolean = when (value) {
            is String, is Int, is Long, is Boolean -> true
            is List<*> -> value.all { it is String || it is Int || it is Long || it is Boolean }
            else -> false
        }

        private fun isJsonSafe(value: Any): Boolean = when (value) {
            is String, is Int, is Long, is Boolean -> true
            is List<*> -> value.all { it != null && isJsonSafe(it) }
            is Map<*, *> -> value.all { (name, nested) -> name is String && nested != null && isJsonSafe(nested) }
            else -> false
        }
    }
}
