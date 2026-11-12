// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

/**
 * The VFS layout the Bot runtime owns.
 *
 * Bot sessions run under a private directory tree below the durable
 * `/dsh/workspace` mount. `botRoot` is `<botDataDirectory>/agents/<botID>`,
 * matching the upstream dsh-bot `<dataRoot>/agents/<botID>/` convention.
 * Attachments stay under the session cwd, in the relative
 * `imports/attachments-<messageID>/` layout the directory-import service has
 * always produced.
 */
public object BotWorkspaceLayout {
    /** Default root used by tests and callers that do not supply the app's data directory. */
    public const val DEFAULT_BOT_DATA_DIRECTORY: String = "/dsh/workspace/.dshbot"

    /** `<botDataDirectory>/agents/<safe botID>`. */
    public fun botRoot(
        botId: String,
        dataDirectory: String = DEFAULT_BOT_DATA_DIRECTORY,
    ): String = "${normalizedDataDirectory(dataDirectory)}/agents/${safePathComponent(botId)}"

    /**
     * A single safe path component for an id that becomes a VFS directory.
     * Keeps the value deterministic so the same Bot always maps to one root.
     */
    public fun safePathComponent(raw: String): String {
        val out = StringBuilder()
        var index = 0
        while (index < raw.length) {
            val codePoint = raw.codePointAt(index)
            val allowed = Character.isLetterOrDigit(codePoint) ||
                codePoint == '.'.code || codePoint == '_'.code || codePoint == '-'.code
            if (allowed) out.appendCodePoint(codePoint) else out.append('_')
            index += Character.charCount(codePoint)
        }
        var output = out.toString()
        if (output.isEmpty() || output == "." || output == "..") output = "bot"
        if (output.length > 64) output = output.substring(0, 64)
        return output
    }

    private fun normalizedDataDirectory(raw: String): String {
        var value = raw
        while (value.length > 1 && value.endsWith("/")) value = value.dropLast(1)
        return value
    }
}
