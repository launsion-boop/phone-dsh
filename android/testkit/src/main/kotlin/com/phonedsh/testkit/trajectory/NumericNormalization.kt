// :testkit trajectory — stage 4: one canonical decimal representation per value domain.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.util.regex.Pattern

/**
 * Stage 4 of `spec/v1/trajectory.md` §5, a decimal port that does not use binary floating
 * point arithmetic (except at the two points where Python's `json` itself does: the source
 * float's shortest `repr`, and `float(Decimal)`).
 *
 * * generic float: round half-even to 6 decimal places; `-0` becomes `0`; an integral result
 *   is emitted as a JSON integer;
 * * duration: round half-even to the nearest 10 ms, integral;
 * * byte count: parse `<number><space?><B|KiB|MiB|GiB>` (1 KiB = 1024) and emit integral
 *   bytes, half-even; negative counts are rejected;
 * * ratio: round half-even to 3 decimal places.
 *
 * The Python `Decimal` context has precision 28. `quantize` raises `InvalidOperation` when the
 * result coefficient would exceed it, and multiplication rounds the result to it; both are
 * mirrored so an out-of-domain number fails instead of silently growing.
 */
internal object NumericNormalizer {
    private val DURATION_MS_MEMBERS = setOf(
        "durationMs",
        "elapsedMs",
        "latencyMs",
        "ttftMs",
        "turnDurationMs",
        "toolDurationMs",
    )
    private val SIZE_MEMBERS = setOf(
        "bytes",
        "sizeBytes",
        "bytesIn",
        "bytesOut",
        "payloadBytes",
        "contentBytes",
    )
    private val RATIO_MEMBERS = setOf("percent", "ratio")

    private const val CONTEXT_PRECISION = 28
    private const val GENERIC_SCALE = 6
    private const val RATIO_SCALE = 3
    private const val DURATION_SCALE = -1 // 1E1: quantize to a multiple of ten

    private val SIZE_PATTERN = Pattern.compile(
        "^[${PythonSemantics.SPACE_CLASS_CHARS}]*([0-9]+(?:\\.[0-9]+)?)" +
            "[${PythonSemantics.SPACE_CLASS_CHARS}]*(B|KiB|MiB|GiB)[${PythonSemantics.SPACE_CLASS_CHARS}]*$",
        Pattern.UNICODE_CHARACTER_CLASS,
    )
    private val PLAIN_INTEGER_PATTERN = Pattern.compile("^[0-9]+$")

    /**
     * Walks the stage's domain (the trajectory `data` object or the UiState `props` object).
     * An array element has no member name, so it is normalized as a generic number — exactly
     * the oracle's `key=None` rule. A string is touched only under a byte-count member.
     */
    fun normalizeNumbers(value: JsonTree, stats: NormalizationStats, where: String, key: String? = null): JsonTree =
        when (value) {
            is JsonObjectTree -> {
                for (name in value.members.keys.toList()) {
                    value.members[name] = normalizeNumbers(
                        value.members.getValue(name),
                        stats,
                        "$where.$name",
                        name,
                    )
                }
                value
            }
            is JsonArrayTree -> {
                for (index in value.items.indices) {
                    value.items[index] = normalizeNumbers(value.items[index], stats, "$where[$index]", null)
                }
                value
            }
            is JsonStringTree -> if (key != null && key in SIZE_MEMBERS) {
                val quantized = quantize(sizeDecimal(value.value, where), 0, where)
                val bytes = integerValue(quantized, where)
                if (bytes.signum() < 0) throw NormError("BAD_NUMBER", where, "byte count is negative")
                // The oracle compares the result with the string it replaced: always different.
                stats.numberRewrites++
                JsonNumberTree(JsonNum.IntValue(bytes))
            } else {
                value
            }
            is JsonNumberTree -> JsonNumberTree(normalizeNumber(value.value, key, where, stats))
            is JsonBoolTree, is JsonNullTree -> value
        }

    private fun normalizeNumber(number: JsonNum, key: String?, where: String, stats: NormalizationStats): JsonNum {
        val normalized: JsonNum = when {
            key != null && key in DURATION_MS_MEMBERS -> {
                val quantized = quantize(decimalOf(number, where), DURATION_SCALE, where)
                JsonNum.IntValue(integerValue(quantized, where))
            }
            key != null && key in SIZE_MEMBERS -> {
                val quantized = quantize(decimalOf(number, where), 0, where)
                val bytes = integerValue(quantized, where)
                if (bytes.signum() < 0) throw NormError("BAD_NUMBER", where, "byte count is negative")
                JsonNum.IntValue(bytes)
            }
            key != null && key in RATIO_MEMBERS -> normalizedDecimal(quantize(decimalOf(number, where), RATIO_SCALE, where))
            else -> when (number) {
                // Integer input stays integer except for duration members, which are quantized.
                is JsonNum.IntValue -> return number
                is JsonNum.FloatValue -> normalizedDecimal(quantize(decimalOf(number, where), GENERIC_SCALE, where))
            }
        }
        if (!numbersEqual(number, normalized)) stats.numberRewrites++
        return normalized
    }

    /** `float(quantized)` when non-integral, `int(quantized)` when integral; `-0` is `0`. */
    private fun normalizedDecimal(quantized: BigDecimal): JsonNum {
        if (quantized.signum() == 0) return JsonNum.IntValue(java.math.BigInteger.ZERO)
        val stripped = quantized.stripTrailingZeros()
        return if (stripped.scale() <= 0) {
            JsonNum.IntValue(stripped.toBigIntegerExact())
        } else {
            JsonNum.FloatValue(stripped.toDouble())
        }
    }

    private fun integerValue(quantized: BigDecimal, where: String): java.math.BigInteger = try {
        quantized.toBigIntegerExact()
    } catch (failure: ArithmeticException) {
        throw NormError("BAD_NUMBER", where, "number cannot be quantized", failure)
    }

    /** Python `Decimal(str(number))`: an integer is exact, a float uses its shortest `repr`. */
    private fun decimalOf(number: JsonNum, where: String): BigDecimal = when (number) {
        is JsonNum.IntValue -> BigDecimal(number.value)
        is JsonNum.FloatValue -> {
            if (!number.value.isFinite()) throw NormError("BAD_NUMBER", where, "number is not finite")
            BigDecimal(PythonSemantics.floatRepr(number.value))
        }
    }

    /** Python `_size_decimal` for a string: `<number><space?><unit>` or a plain integer. */
    private fun sizeDecimal(text: String, where: String): BigDecimal {
        val matcher = SIZE_PATTERN.matcher(text)
        if (matcher.matches()) {
            val amount = BigDecimal(matcher.group(1))
            val multiplier = when (matcher.group(2)) {
                "B" -> BIG_ONE
                "KiB" -> BIG_KIB
                "MiB" -> BIG_MIB
                "GiB" -> BIG_GIB
                else -> throw NormError("BAD_NUMBER", where, "byte count has an unknown unit")
            }
            return multiplyWithContext(amount, multiplier)
        }
        if (PLAIN_INTEGER_PATTERN.matcher(text).matches()) return BigDecimal(text)
        throw NormError("BAD_NUMBER", where, "byte count is not a number with a known unit")
    }

    private fun multiplyWithContext(left: BigDecimal, right: BigDecimal): BigDecimal {
        val product = left.multiply(right)
        return if (product.precision() > CONTEXT_PRECISION) {
            product.round(MathContext(CONTEXT_PRECISION, RoundingMode.HALF_EVEN))
        } else {
            product
        }
    }

    /** `Decimal.quantize(1E<scale>)`, including its context-precision `InvalidOperation`. */
    private fun quantize(decimal: BigDecimal, scale: Int, where: String): BigDecimal {
        val result = decimal.setScale(scale, RoundingMode.HALF_EVEN)
        if (result.unscaledValue().abs().toString().length > CONTEXT_PRECISION) {
            throw NormError("BAD_NUMBER", where, "number cannot be quantized")
        }
        return result
    }

    /** Python numeric equality, used only for the `numberRewrites` counter. */
    private fun numbersEqual(left: JsonNum, right: JsonNum): Boolean = when {
        left is JsonNum.IntValue && right is JsonNum.IntValue -> left.value == right.value
        left is JsonNum.FloatValue && right is JsonNum.FloatValue -> left.value == right.value
        left is JsonNum.IntValue && right is JsonNum.FloatValue ->
            right.value.isFinite() && BigDecimal(left.value).compareTo(BigDecimal(right.value)) == 0
        left is JsonNum.FloatValue && right is JsonNum.IntValue ->
            left.value.isFinite() && BigDecimal(left.value).compareTo(BigDecimal(right.value)) == 0
        else -> false
    }

    private val BIG_ONE: BigDecimal = BigDecimal.ONE
    private val BIG_KIB: BigDecimal = BigDecimal(1024)
    private val BIG_MIB: BigDecimal = BigDecimal(1024 * 1024)
    private val BIG_GIB: BigDecimal = BigDecimal(1024 * 1024 * 1024)
}
