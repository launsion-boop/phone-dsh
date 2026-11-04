// The chat page's 导出对话记录: one Markdown document, then the platform share sheet.
// SPDX-License-Identifier: MIT
//
// Mirror source: `ChatPage.swift:3181`–`:3205` (`historyExport` + `exportTitle`).
// The page owns the menu row and nothing else: this host file builds the document
// from the same folded `ChatRow`s the transcript draws, then hands it to the one
// platform mechanism Android has for 分享 — an `ACTION_SEND` chooser.
//
// The Markdown builder is pure so a JVM test can pin the section format without a
// device. Only [shareChatTranscript] touches the platform. A long document goes to
// `cacheDir/transcript-exports/` behind the app's own FileProvider; when that
// provider or the chooser cannot start, the person sees why instead of a tap that
// silently did nothing, and the text is never silently cut.
package com.phonedsh.probe

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ToolEntry
import com.phonedsh.ui.state.contextSourceName
import com.phonedsh.ui.surface.ToolRowState
import java.io.File

/** The document's opening line and every non-status row, in transcript order. */
internal fun chatTranscriptMarkdown(title: String, rows: List<ChatRow>): String {
    val blocks = buildList {
        add("# ${title.trim().ifBlank { UiStrings.SESSION_TITLE_NEW }}")
        rows.forEach { addAll(it.transcriptBlocks()) }
    }
    return blocks.joinToString("\n\n")
}

/** One row's sections; a tool run and a group expand to their own rows. */
private fun ChatRow.transcriptBlocks(): List<String> = when (this) {
    is ChatRow.User -> listOf(
        block(
            if (badge == UiStrings.STEERED_TAG) UiStrings.CHAT_EXPORT_TITLE_STEERING else UiStrings.CHAT_EXPORT_TITLE_YOU,
            text,
        ),
    )

    is ChatRow.Assistant -> listOf(block(UiStrings.CHAT_EXPORT_TITLE_DSH, text))

    is ChatRow.Thinking -> listOf(block(UiStrings.THINKING, summary))

    is ChatRow.ToolRun -> entries.flatMap { it.transcriptBlocks() }

    is ChatRow.ProcessGroup -> entries.flatMap { it.transcriptBlocks() }

    is ChatRow.TurnProcess -> entries.flatMap { it.transcriptBlocks() }

    // The closing assistant text is also inside the turn's process entries; the
    // tail is chrome, not a second message.
    is ChatRow.TurnTail -> emptyList()

    is ChatRow.Context -> entries.map { entry ->
        val source = contextSourceName(entry.source)
        block(
            if (source == null) UiStrings.CHAT_EXPORT_TITLE_CONTEXT else "${UiStrings.CHAT_EXPORT_TITLE_CONTEXT} · $source",
            entry.text,
        )
    }

    is ChatRow.QuestionReply -> listOf(block(UiStrings.CHAT_EXPORT_TITLE_YOU, text))

    // iOS skips `kind == .status`; the Android system-event row is that status.
    is ChatRow.SystemEvent -> emptyList()
}

/** A tool entry can hold the call and its result (iOS keeps two items). */
private fun ToolEntry.transcriptBlocks(): List<String> = buildList {
    val rendered = body.ifBlank { summary }
    val hasCall = arguments != null || state == ToolRowState.RUNNING
    if (hasCall) {
        val name = title.ifBlank { banner }.ifBlank { variant.name.lowercase() }
        val callText = arguments?.toJsonString()?.takeIf { it.isNotBlank() } ?: rendered
        add(block("${UiStrings.CHAT_EXPORT_TITLE_TOOL_CALL} · $name", callText))
    }
    if (state != ToolRowState.RUNNING) {
        // Only a real failure is 工具错误. STOPPED is a separately reported
        // non-error state (the person interrupted the turn), and the iOS exporter
        // maps only `isError` to its tool-error section; an interrupted call
        // therefore keeps the result heading.
        val heading = if (state == ToolRowState.ERROR) {
            UiStrings.CHAT_EXPORT_TITLE_TOOL_ERROR
        } else {
            UiStrings.CHAT_EXPORT_TITLE_TOOL_RESULT
        }
        add(block(heading, rendered))
    }
}

private fun block(heading: String, text: String): String = "### $heading\n\n$text"

/**
 * Starts the share chooser for [markdown].
 *
 * @return `null` when the chooser started, or the visible failure sentence.
 */
internal fun shareChatTranscript(context: Context, title: String, markdown: String): String? {
    if (markdown.length > TRANSCRIPT_INLINE_LIMIT) {
        val file = writeTranscriptCacheFile(context, title, markdown)
            ?: return UiStrings.CHAT_EXPORT_TOO_LONG
        val uri = transcriptUri(context, file) ?: return UiStrings.CHAT_EXPORT_TOO_LONG
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/markdown"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, title.trim().ifBlank { UiStrings.SESSION_TITLE_NEW })
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return startChooser(context, send)
    }
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/markdown"
        putExtra(Intent.EXTRA_TEXT, markdown)
        putExtra(Intent.EXTRA_SUBJECT, title.trim().ifBlank { UiStrings.SESSION_TITLE_NEW })
    }
    return startChooser(context, send)
}

/** The inline text ceiling; above it the document must travel as a file. */
internal const val TRANSCRIPT_INLINE_LIMIT: Int = 12_000

/** The FileProvider authority the app manifest declares for this cache directory. */
internal const val TRANSCRIPT_PROVIDER_SUFFIX: String = ".pdsh.transcript"

/**
 * The share provider for generated transcript files.
 *
 * A distinct class from the library's preview provider: both extend
 * `FileProvider`, and the manifest merger keys providers by class, so reusing the
 * library class here would merge the two authorities instead of declaring two
 * providers (measured: `Attribute provider#FileProvider@authorities ... is also
 * present`).
 */
public class TranscriptFileProvider : FileProvider()

private const val TRANSCRIPT_CACHE_DIRECTORY: String = "transcript-exports"

private fun startChooser(context: Context, send: Intent): String? {
    val chooser = Intent.createChooser(send, UiStrings.CHAT_EXPORT_CHOOSER)
    return try {
        val activity = context.findActivity()
        if (activity != null) {
            activity.startActivity(chooser)
        } else {
            context.startActivity(chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        null
    } catch (_: ActivityNotFoundException) {
        UiStrings.CHAT_EXPORT_FAILED
    } catch (_: SecurityException) {
        UiStrings.CHAT_EXPORT_FAILED
    }
}

private fun writeTranscriptCacheFile(context: Context, title: String, markdown: String): File? {
    return try {
        val directory = File(context.cacheDir, TRANSCRIPT_CACHE_DIRECTORY)
        if (!directory.isDirectory && !directory.mkdirs()) return null
        val safe = title.trim()
            .replace(Regex("[^\\p{L}\\p{N}._-]+"), "_")
            .trim('_', '.', '-')
            .take(48)
            .ifBlank { "transcript" }
        File(directory, "$safe-${System.currentTimeMillis()}.md").apply {
            writeText(markdown, Charsets.UTF_8)
        }
    } catch (_: Exception) {
        null
    }
}

private fun transcriptUri(context: Context, file: File): Uri? = try {
    FileProvider.getUriForFile(context, context.packageName + TRANSCRIPT_PROVIDER_SUFFIX, file)
} catch (_: IllegalArgumentException) {
    null
}

private fun Context.findActivity(): android.app.Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is android.app.Activity) return current
        current = current.baseContext
    }
    return current as? android.app.Activity
}
