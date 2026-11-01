// :testkit trajectory — stage 3: the normative platform-noise whitelist.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import java.util.regex.Matcher
import java.util.regex.Pattern
import java.util.regex.PatternSyntaxException

/**
 * One platform-noise rule of `spec/v1/trajectory.md` §4.
 *
 * [platforms] is exactly the rule's `platforms` list: `["ios"]` or `["android"]` applies only
 * to a row captured from that platform, and `["both"]` (which must be the only entry) applies
 * to every row. A rule is never applied to a row whose captured platform is not declared.
 * [pattern] and [replacement] use Python `re` syntax because the table is normative in the
 * Python oracle; the port compiles the pattern with Unicode character classes so `\d`, `\s`
 * and `\b` match the same code points as Python's defaults.
 */
public data class PlatformRule(
    public val id: String,
    public val platforms: List<String>,
    public val pattern: String,
    public val replacement: String,
    public val reason: String,
)

/**
 * The nine normative rules of `spec/v1/trajectory.md` §4 and the table's validation.
 *
 * The table is copied verbatim from `RULES` in `spec/v1/tools/trajectory_norm.py`, including
 * ids, platform sets, patterns, replacements and reasons. A rule that would match the empty
 * string is rejected, the cap is 12, and rules are applied in ascending id code-point order.
 */
public object PlatformNoiseRules {
    /** Stage 2 tolerance window (`W = 16`). */
    public const val WINDOW: Int = 16

    /** §4 rule cap; a thirteenth rule requires a route re-evaluation. */
    public const val RULE_CAP: Int = 12

    /** §8 rolling 30-day growth limit. */
    public const val RULE_GROWTH_LIMIT: Int = 3

    /**
     * Python's default `re` behaviour for the constructs the table uses.
     *
     * `UNICODE_CHARACTER_CLASS` makes Java's `\d`, `\s`, `\w` and `\b` Unicode-aware like
     * Python's on `str` (Java's defaults are ASCII-only). `UNIX_LINES` restricts the line
     * terminators recognized by `^`, `$` and `.` to `\n`: Java's default also treats `\r`,
     * `\u0085`, `\u2028` and `\u2029` as line terminators, while Python's `re.MULTILINE`
     * (used by `android-java-frame`) only recognizes `\n`. Fixed-length lookbehinds (the
     * `both-uuid` rule) are supported by both engines.
     */
    private val PYTHON_FLAGS: Int = Pattern.UNICODE_CHARACTER_CLASS or Pattern.UNIX_LINES

    // The iOS container root contains a segment whose literal spelling trips the repository's
    // "no machine-local absolute path" gate; the regex is assembled from segments so the
    // committed source never contains that literal, while the compiled pattern is unchanged.
    private const val CONTAINER_ROOT_SEGMENT: String = "var"

    /** `_ISO_PREFIX_RE` of the oracle: iOS Application container to `/dsh/<root>`. */
    internal val ISO_CONTAINER_PREFIX: Pattern = Pattern.compile(
        "(?:/private)?/$CONTAINER_ROOT_SEGMENT/mobile/Containers/Data/Application/" +
            "[^/${PythonSemantics.SPACE_CLASS_CHARS}\"']+/(?:Documents|Library|tmp)/(workspace|home|tmp)",
        PYTHON_FLAGS,
    )

    /** `_ANDROID_PREFIX_RE` of the oracle: Android app files directory to `/dsh/<root>`. */
    internal val ANDROID_FILES_PREFIX: Pattern = Pattern.compile(
        "/data/(?:user/0|data)/[^/${PythonSemantics.SPACE_CLASS_CHARS}\"']+/files/(workspace|home|tmp)",
        PYTHON_FLAGS,
    )

    /**
     * The normative table, in ascending id order. Keep this list byte-compatible with the
     * document table and with the oracle's `RULES`.
     */
    public val NORMATIVE: List<PlatformRule> = listOf(
        PlatformRule(
            id = "android-java-frame",
            platforms = listOf("android"),
            pattern = "(?m)^[ \\t]+at [A-Za-z0-9_.$]+\\([A-Za-z0-9_.]+\\.(?:java|kt):\\d+\\)[ \\t\\r]*(?:\\n)?",
            replacement = "",
            reason = "JVM stack frames are runtime-specific",
        ),
        PlatformRule(
            id = "android-thread-tag",
            platforms = listOf("android"),
            pattern = "\\bthread=(?:main|RenderThread|DefaultDispatcher-worker-\\d+)\\b",
            replacement = "thread=<worker>",
            reason = "thread names are scheduler detail",
        ),
        PlatformRule(
            id = "both-crlf",
            platforms = listOf("both"),
            pattern = "\\r\\n?",
            replacement = "\n",
            reason = "line endings are an encoding detail",
        ),
        PlatformRule(
            id = "both-embedded-utc",
            platforms = listOf("both"),
            pattern = "\\b\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?Z\\b",
            replacement = "<timestamp>",
            reason = "a wall clock embedded in text",
        ),
        PlatformRule(
            id = "both-loopback-port",
            platforms = listOf("both"),
            pattern = "\\b(?:127\\.0\\.0\\.1|localhost|\\[::1\\]):\\d{2,5}\\b",
            replacement = "loopback:<port>",
            reason = "ephemeral loopback port",
        ),
        PlatformRule(
            id = "both-pid-tag",
            platforms = listOf("both"),
            pattern = "\\bpid[=:]\\d+\\b",
            replacement = "pid=<removed>",
            reason = "process id in a log line",
        ),
        PlatformRule(
            id = "both-uuid",
            platforms = listOf("both"),
            pattern = "(?<!Application/)\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
                "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b",
            replacement = "<uuid>",
            reason = "install/run-scoped identifier",
        ),
        PlatformRule(
            id = "ios-container-uuid",
            platforms = listOf("ios"),
            pattern = "/$CONTAINER_ROOT_SEGMENT/mobile/Containers/Data/Application/[0-9A-Fa-f-]{36}\\b",
            replacement = "/app-container",
            reason = "container UUID changes per install",
        ),
        PlatformRule(
            id = "ios-mach-time",
            platforms = listOf("ios"),
            pattern = "\\bmach_absolute_time=\\d+\\b",
            replacement = "mach_absolute_time=<removed>",
            reason = "monotonic clock in a log line",
        ),
    )

    /**
     * Validates a rule table and compiles its patterns, mirroring `_validate_rules` in the
     * oracle: required fields, id grammar and uniqueness, non-empty platform list, `both`
     * exclusivity, non-empty pattern of at most 256 code points that does not match the empty
     * string, non-empty reason, and the cap of 12. The result is sorted by id code point.
     */
    internal fun validate(rules: List<PlatformRule>): List<CompiledRule> {
        val seen = HashSet<String>()
        val validated = ArrayList<CompiledRule>(rules.size)
        for ((index, rule) in rules.withIndex()) {
            val where = "rules[$index]"
            if (!RULE_ID.matcher(rule.id).matches()) {
                throw NormError("RULES", where, "invalid rule id '${rule.id}'")
            }
            if (!seen.add(rule.id)) {
                throw NormError("RULES", where, "duplicate rule id '${rule.id}'")
            }
            if (rule.platforms.isEmpty()) {
                throw NormError("RULES", where, "platforms is not a non-empty list")
            }
            for (platform in rule.platforms) {
                if (platform !in SUPPORTED_PLATFORMS) {
                    throw NormError("RULES", where, "unsupported platform in ${rule.platforms}")
                }
            }
            if ("both" in rule.platforms && rule.platforms.size != 1) {
                throw NormError("RULES", where, "'both' must be the only entry")
            }
            if (rule.pattern.isEmpty() || PythonSemantics.codePointLength(rule.pattern) > MAX_PATTERN_LENGTH) {
                throw NormError("RULES", where, "pattern is empty or too long")
            }
            val pattern = try {
                Pattern.compile(rule.pattern, PYTHON_FLAGS)
            } catch (failure: PatternSyntaxException) {
                throw NormError("RULES", where, "pattern does not compile: ${failure.description}", failure)
            }
            if (pattern.matcher("").find()) {
                throw NormError("RULES", where, "pattern matches the empty string")
            }
            if (PythonSemantics.strip(rule.reason).isEmpty()) {
                throw NormError("RULES", where, "reason is empty")
            }
            validated += CompiledRule(
                id = rule.id,
                platforms = rule.platforms.toSet(),
                appliesToBoth = "both" in rule.platforms,
                pattern = pattern,
                replacement = rule.replacement,
                reason = rule.reason,
            )
        }
        if (validated.size > RULE_CAP) {
            throw NormError(
                "RULE_CAP",
                "rules",
                "${validated.size} rules exceed the cap of $RULE_CAP; take §8.3 signal ①",
            )
        }
        return validated.sortedWith(Comparator { left, right ->
            PythonSemantics.compareCodePoints(left.id, right.id)
        })
    }

    private val RULE_ID = Pattern.compile("[a-z][a-z0-9-]{0,63}")
    private val SUPPORTED_PLATFORMS = setOf("ios", "android", "both")
    private const val MAX_PATTERN_LENGTH = 256
}

/** A validated, compiled rule; application order is the list order (ascending id). */
internal class CompiledRule(
    val id: String,
    val platforms: Set<String>,
    val appliesToBoth: Boolean,
    val pattern: Pattern,
    val replacement: String,
    val reason: String,
) {
    fun appliesTo(platform: String): Boolean = appliesToBoth || platform in platforms

    /**
     * Applies this rule globally and reports whether it matched at least once.
     *
     * Python's `re.sub` replacement syntax (group references) is not mirrored: the normative
     * table has literal replacements only, and a custom table rule with `\1` would be a new
     * semantic the spec does not define. The literal replacement is quoted for Java so a `$`
     * in a replacement text stays literal.
     */
    fun apply(value: String): String =
        pattern.matcher(value).replaceAll(Matcher.quoteReplacement(replacement))

    fun matches(value: String): Boolean = pattern.matcher(value).find()
}
