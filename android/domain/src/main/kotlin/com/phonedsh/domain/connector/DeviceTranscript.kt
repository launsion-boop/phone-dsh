// A device session's transcript: durable records in, display rows out.
// SPDX-License-Identifier: MIT
//
// The decoder-at-the-edge rule that `ConnectedDevice` already states applies here
// too: a transport hands back typed records, never the raw JSON `session/page`
// carried, so the projection below has one input shape and no parser of its own.
// The projection is a pure function of the ordered records, which is what lets the
// session page be replayed on the JVM without a device or a socket.
//
// The item vocabulary is the phone mirror of the iOS probe's
// `DeviceTranscriptItem` (`examples/probe-app/PhoneDSHProbe/DeviceTranscriptProjection.swift`):
// the same kinds, the same tool states and the same per-block split of an
// assistant message. It lives in `:domain` rather than in the page so the pager,
// the live merge and the page all name one type.
package com.phonedsh.domain.connector

/** One attachment a row names. A name and whether it is a picture, nothing more. */
data class DeviceAttachment(
    val name: String,
    val isImage: Boolean,
)

/**
 * One content block of an assistant message.
 *
 * `tool-call` blocks are deliberately absent: a tool call arrives as its own
 * `tool/call` record, and projecting it from inside the message too would render
 * the same call twice.
 */
sealed interface DeviceContentBlock {
    /** Visible assistant prose. */
    data class Text(val text: String) : DeviceContentBlock

    /** A reasoning block; shown collapsed, under 思考. */
    data class Reasoning(val text: String) : DeviceContentBlock

    /** An image block; the row carries the attachment labels only. */
    data object Image : DeviceContentBlock

    /** A block this host does not render; the row shows the raw shape instead of hiding it. */
    data class Unknown(val json: String) : DeviceContentBlock
}

/**
 * One durable row of a device session, as `session/page` publishes it.
 *
 * @property seq the session's own sequence number; the pager orders by it and
 *   `beforeSeq` is derived from it.
 * @property turn the turn the record belongs to, when the record names one.
 * @property step the step within the turn, when named.
 * @property timeMs the record's timestamp in epoch milliseconds, when named.
 */
sealed interface DeviceTranscriptRecord {
    val seq: Long
    val turn: Int?
    val step: Int?
    val timeMs: Long?

    /**
     * A message the device or the phone user typed.
     *
     * @property deviceOrigin true when the message came from the device, which is
     *   a first-class participant of the fixed session: the phone user and the
     *   device must not collapse into one row.
     * @property context true when the message is host-injected context rather than
     *   either participant.
     */
    data class UserMessage(
        override val seq: Long,
        val text: String,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
        val deviceOrigin: Boolean = false,
        val context: Boolean = false,
        val attachments: List<DeviceAttachment> = emptyList(),
    ) : DeviceTranscriptRecord

    /** One assistant message, projected block by block. */
    data class AssistantMessage(
        override val seq: Long,
        val blocks: List<DeviceContentBlock>,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
    ) : DeviceTranscriptRecord

    /**
     * A tool invocation.
     *
     * @property callId the id a later [ToolResult] patches this row by.
     * @property argumentsJson the arguments as the device sent them (already a
     *   string: the row shows it monospaced, it does not re-encode it).
     */
    data class ToolCall(
        override val seq: Long,
        val callId: String,
        val name: String,
        val argumentsJson: String,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
    ) : DeviceTranscriptRecord

    /**
     * The result of a [ToolCall].
     *
     * @property interrupted true when the device's own record says the tool was
     *   interrupted, which is `stopped`, not `failed`.
     */
    data class ToolResult(
        override val seq: Long,
        val callId: String,
        val isError: Boolean,
        val output: String,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
        val interrupted: Boolean = false,
        val toolName: String? = null,
    ) : DeviceTranscriptRecord

    /**
     * The end of a turn.
     *
     * @property reason the device's reason tag (`max-tokens`, `error`, `aborted`,
     *   `interrupted`, `completed`, ...); the projection only acts on the first
     *   four because those are the ones a page must say out loud.
     * @property errorMessage the model failure's message, when the reason is `error`.
     */
    data class TurnEnd(
        override val seq: Long,
        val reason: String,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
        val errorMessage: String? = null,
    ) : DeviceTranscriptRecord

    /** A host notice (a model retry, for example). Rendered as one information line. */
    data class Notice(
        override val seq: Long,
        val title: String,
        val text: String,
        override val turn: Int? = null,
        override val step: Int? = null,
        override val timeMs: Long? = null,
    ) : DeviceTranscriptRecord
}

/** What one projected row is; the page picks a renderer per kind. */
enum class DeviceItemKind {
    /** The phone user's own message. */
    USER,

    /** A message the device sent. */
    DEVICE,

    /** Host-injected context, shown as a secondary row rather than as a participant. */
    CONTEXT,

    /** Assistant prose. */
    ASSISTANT,

    /** A reasoning block. */
    REASONING,

    /** An assistant image block. */
    IMAGE,

    /** A tool invocation. */
    TOOL_CALL,

    /** A tool result that matched no call in the window. */
    TOOL_RESULT,

    /** A host notice. */
    SYSTEM_EVENT,

    /** A turn that ended in a model failure. */
    TURN_ERROR,

    /** A turn that ended because the output budget was reached. */
    MAX_TOKENS,

    /** A block or record this host does not render. */
    UNKNOWN,
}

/** A tool row's state; `null` means "running", as the iOS row reads it. */
enum class DeviceToolState {
    RUNNING,
    OK,
    ERROR,
    STOPPED,
}

/**
 * One display row of the device transcript.
 *
 * @property id stable across a re-projection of the same records, so a lazy list
 *   and a fold keyed by it survive a page append.
 * @property streaming true while a live delta is still being appended to [text].
 */
data class DeviceTranscriptItem(
    val id: String,
    val kind: DeviceItemKind,
    val title: String,
    val text: String,
    val streaming: Boolean = false,
    val timestampMs: Long? = null,
    val turn: Int? = null,
    val step: Int? = null,
    val callId: String? = null,
    val toolName: String? = null,
    val argumentsJson: String? = null,
    val outputText: String? = null,
    val toolState: DeviceToolState? = null,
    val attachments: List<DeviceAttachment> = emptyList(),
)

/**
 * Projects ordered durable records into display rows.
 *
 * Pure and total: an unknown record never throws and never disappears silently —
 * it becomes an [DeviceItemKind.UNKNOWN] row carrying its own JSON shape.
 */
object DeviceTranscriptProjector {
    /** The empty assistant text a streaming row shows before its first delta. */
    const val PLACEHOLDER: String = "…"

    /**
     * Projects [records] (already in consequence order).
     *
     * @param sessionId prefixes every row id, so two sessions never share one.
     */
    fun items(records: List<DeviceTranscriptRecord>, sessionId: String): List<DeviceTranscriptItem> {
        val result = mutableListOf<DeviceTranscriptItem>()
        val calls = HashMap<String, Int>()
        for (record in records) {
            val id = "$sessionId:${record.seq}"
            when (record) {
                is DeviceTranscriptRecord.UserMessage -> {
                    if (record.text.isEmpty() && record.attachments.isEmpty()) continue
                    val kind = when {
                        record.deviceOrigin -> DeviceItemKind.DEVICE
                        record.context -> DeviceItemKind.CONTEXT
                        else -> DeviceItemKind.USER
                    }
                    val title = when (kind) {
                        DeviceItemKind.DEVICE -> TITLE_DEVICE
                        DeviceItemKind.CONTEXT -> TITLE_CONTEXT
                        else -> TITLE_USER
                    }
                    result += DeviceTranscriptItem(
                        id = id,
                        kind = kind,
                        title = title,
                        text = record.text,
                        timestampMs = record.timeMs,
                        turn = record.turn,
                        step = record.step,
                        attachments = record.attachments,
                    )
                }

                is DeviceTranscriptRecord.AssistantMessage -> {
                    record.blocks.forEachIndexed { index, block ->
                        val kind = when (block) {
                            is DeviceContentBlock.Text -> DeviceItemKind.ASSISTANT
                            is DeviceContentBlock.Reasoning -> DeviceItemKind.REASONING
                            DeviceContentBlock.Image -> DeviceItemKind.IMAGE
                            is DeviceContentBlock.Unknown -> DeviceItemKind.UNKNOWN
                        }
                        val text = when (block) {
                            is DeviceContentBlock.Text -> block.text
                            is DeviceContentBlock.Reasoning -> block.text
                            DeviceContentBlock.Image -> ""
                            is DeviceContentBlock.Unknown -> block.json
                        }
                        if (text.isBlank() && kind != DeviceItemKind.IMAGE && kind != DeviceItemKind.UNKNOWN) {
                            return@forEachIndexed
                        }
                        result += DeviceTranscriptItem(
                            id = "$id:block-$index",
                            kind = kind,
                            title = if (kind == DeviceItemKind.REASONING) TITLE_REASONING else TITLE_ASSISTANT,
                            text = text,
                            timestampMs = record.timeMs,
                            turn = record.turn,
                            step = record.step,
                            attachments = if (kind == DeviceItemKind.IMAGE) {
                                listOf(DeviceAttachment(TITLE_IMAGE, isImage = true))
                            } else {
                                emptyList()
                            },
                        )
                    }
                }

                is DeviceTranscriptRecord.ToolCall -> {
                    val item = DeviceTranscriptItem(
                        id = id,
                        kind = DeviceItemKind.TOOL_CALL,
                        title = record.name,
                        text = record.argumentsJson,
                        timestampMs = record.timeMs,
                        turn = record.turn,
                        step = record.step,
                        callId = record.callId,
                        toolName = record.name,
                        argumentsJson = record.argumentsJson,
                        toolState = DeviceToolState.RUNNING,
                    )
                    if (record.callId.isNotEmpty()) calls[record.callId] = result.size
                    result += item
                }

                is DeviceTranscriptRecord.ToolResult -> {
                    val index = calls[record.callId]
                    val state = if (record.interrupted) {
                        DeviceToolState.STOPPED
                    } else if (record.isError) {
                        DeviceToolState.ERROR
                    } else {
                        DeviceToolState.OK
                    }
                    if (index != null) {
                        result[index] = result[index].copy(outputText = record.output, toolState = state)
                    } else {
                        result += DeviceTranscriptItem(
                            id = id,
                            kind = DeviceItemKind.TOOL_RESULT,
                            title = if (record.isError) TITLE_TOOL_ERROR else TITLE_TOOL_RESULT,
                            text = record.output,
                            timestampMs = record.timeMs,
                            turn = record.turn,
                            step = record.step,
                            callId = record.callId,
                            toolName = record.toolName,
                            outputText = record.output,
                            toolState = state,
                        )
                    }
                }

                is DeviceTranscriptRecord.TurnEnd -> {
                    when (record.reason) {
                        REASON_MAX_TOKENS -> result += DeviceTranscriptItem(
                            id = id,
                            kind = DeviceItemKind.MAX_TOKENS,
                            title = TITLE_MAX_TOKENS,
                            text = TEXT_MAX_TOKENS,
                            timestampMs = record.timeMs,
                            turn = record.turn,
                            step = record.step,
                        )

                        REASON_ERROR -> result += DeviceTranscriptItem(
                            id = id,
                            kind = DeviceItemKind.TURN_ERROR,
                            title = TITLE_TURN_ERROR,
                            text = record.errorMessage ?: TEXT_TURN_ERROR,
                            timestampMs = record.timeMs,
                            turn = record.turn,
                            step = record.step,
                        )
                    }
                    if (record.reason in STOPPING_REASONS) {
                        val turn = record.turn
                        for (i in result.indices) {
                            if (result[i].turn == turn && result[i].toolState == DeviceToolState.RUNNING) {
                                result[i] = result[i].copy(toolState = DeviceToolState.STOPPED)
                            }
                        }
                    }
                }

                is DeviceTranscriptRecord.Notice -> result += DeviceTranscriptItem(
                    id = id,
                    kind = DeviceItemKind.SYSTEM_EVENT,
                    title = record.title,
                    text = record.text,
                    timestampMs = record.timeMs,
                    turn = record.turn,
                    step = record.step,
                )
            }
        }
        return result
    }

    /** The titles the projection prints; the page reuses them so both agree. */
    const val TITLE_USER: String = "你"
    const val TITLE_DEVICE: String = "设备"
    const val TITLE_CONTEXT: String = "设备上下文"
    const val TITLE_ASSISTANT: String = "Assistant"
    const val TITLE_REASONING: String = "思考"
    const val TITLE_IMAGE: String = "图片"
    const val TITLE_TOOL_RESULT: String = "工具结果"
    const val TITLE_TOOL_ERROR: String = "工具失败"
    const val TITLE_MAX_TOKENS: String = "输出已达到上限"
    const val TITLE_TURN_ERROR: String = "本轮执行失败"

    /** The two turn-end sentences; the device is where anything further happens. */
    const val TEXT_MAX_TOKENS: String = "回答被截断；请在设备上继续处理。"
    const val TEXT_TURN_ERROR: String = "模型服务出错了"

    private const val REASON_MAX_TOKENS = "max-tokens"
    private const val REASON_ERROR = "error"
    private val STOPPING_REASONS = setOf("aborted", "interrupted", "error")
}
