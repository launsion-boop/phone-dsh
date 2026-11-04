// The live half of a device session's transcript.
// SPDX-License-Identifier: MIT
//
// A device session has two sources of rows and they are not the same kind of
// fact. The **durable** half is what `session/page` published: ordered by `seq`,
// re-readable, stable. The **live** half is a delta stream: a reasoning sentence
// arrives a token at a time, a tool result arrives while its call row is already
// on screen. The session page shows both, in the order the session produced them,
// and the durable half is never re-projected to include a live row (a live row has
// no durable identity yet — it gets one when the next history read publishes it).
//
// The merge is therefore a pure fold over one event at a time, exactly like the
// iOS model's `apply(_ event:)`, so a JVM test can replay a delta sequence and
// assert the coalesced text, the streaming flag and the tool state without a
// coroutine, a clock or a renderer.
package com.phonedsh.domain.connector

/**
 * One event from the device session's live stream.
 *
 * The set is the subset of the harness vocabulary a read-only monitor renders;
 * everything else (`usage`, permission asks, compaction, ...) is deliberately
 * absent because a monitor cannot act on it. A transport that receives such an
 * event drops it rather than inventing a row for it.
 */
sealed interface DeviceLiveEvent {
    /** The event's own sequence number, when the stream carries one. */
    val seq: Long?

    /** A reasoning fragment; appended to the open reasoning row. */
    data class ReasoningDelta(val text: String, override val seq: Long? = null) : DeviceLiveEvent

    /** An assistant fragment; appended to the open assistant row. */
    data class AssistantDelta(val text: String, override val seq: Long? = null) : DeviceLiveEvent

    /** A completed assistant message; closes the open assistant row. */
    data class AssistantMessage(val text: String, override val seq: Long? = null) : DeviceLiveEvent

    /** A message the device sent. */
    data class UserMessage(val text: String, override val seq: Long? = null) : DeviceLiveEvent

    /** A tool invocation that has started. */
    data class ToolCall(
        val callId: String,
        val name: String,
        val argumentsJson: String,
        override val seq: Long? = null,
    ) : DeviceLiveEvent

    /** A tool result; patches the call row it names, whether live or durable. */
    data class ToolResult(
        val callId: String,
        val isError: Boolean,
        val output: String,
        override val seq: Long? = null,
        val interrupted: Boolean = false,
    ) : DeviceLiveEvent

    /** A turn began. */
    data class TurnStarted(val turnId: Long, override val seq: Long? = null) : DeviceLiveEvent

    /** A turn ended; open streaming rows are closed. */
    data class TurnEnded(override val seq: Long? = null) : DeviceLiveEvent

    /** A progress report; the step phase advances the active step. */
    data class Progress(
        val phase: String,
        val step: Int?,
        override val seq: Long? = null,
    ) : DeviceLiveEvent
}

/** One tool result a live event reported, kept so a durable row can be patched by it. */
data class DeviceToolOutput(
    val callId: String,
    val text: String,
    val state: DeviceToolState,
)

/**
 * The live rows of one monitored session, plus the small amount of turn context a
 * delta needs to be placed on the right turn.
 *
 * @property items the live rows, in arrival order.
 * @property activeTurn the turn a new row is stamped with, when known.
 * @property activeStep the step a new row is stamped with, when known.
 * @property toolOutputs every tool result seen live, by call id. Applied to the
 *   durable projection as well, because a result can arrive for a call that the
 *   last history read already published.
 */
data class DeviceLiveState(
    val items: List<DeviceTranscriptItem> = emptyList(),
    val activeTurn: Int? = null,
    val activeStep: Int? = null,
    val toolOutputs: Map<String, DeviceToolOutput> = emptyMap(),
) {
    /**
     * Folds one event in.
     *
     * @param sessionId prefixes a new row's id; a live row without a `seq` gets a
     *   stable position id (`live-<n>`) so a re-composition cannot duplicate it.
     * @param durable the durable projection currently on screen. A tool result whose
     *   call is already durable patches that row and adds no live row — the same
     *   two-place lookup the iOS model performs over `liveItems` then `durableItems`.
     */
    fun apply(
        event: DeviceLiveEvent,
        sessionId: String,
        durable: List<DeviceTranscriptItem> = emptyList(),
    ): DeviceLiveState {
        val id = when (val seq = event.seq) {
            null -> "$sessionId:live-${items.size}"
            else -> "$sessionId:live-$seq"
        }
        return when (event) {
            is DeviceLiveEvent.ReasoningDelta -> appendDelta(
                id = id,
                kind = DeviceItemKind.REASONING,
                title = DeviceTranscriptProjector.TITLE_REASONING,
                text = event.text,
                timestampMs = null,
            )

            is DeviceLiveEvent.AssistantDelta -> appendDelta(
                id = id,
                kind = DeviceItemKind.ASSISTANT,
                title = DeviceTranscriptProjector.TITLE_ASSISTANT,
                text = event.text,
                timestampMs = null,
                closeReasoning = true,
            )

            is DeviceLiveEvent.AssistantMessage -> {
                val closed = finishReasoning()
                val last = closed.items.lastOrNull()
                when {
                    last != null && last.kind == DeviceItemKind.ASSISTANT && last.streaming ->
                        closed.copy(
                            items = closed.items.dropLast(1) + last.copy(
                                text = if (event.text.isEmpty()) last.text else event.text,
                                streaming = false,
                            ),
                        )

                    event.text.isNotEmpty() -> closed.copy(
                        items = closed.items + DeviceTranscriptItem(
                            id = id,
                            kind = DeviceItemKind.ASSISTANT,
                            title = DeviceTranscriptProjector.TITLE_ASSISTANT,
                            text = event.text,
                            turn = closed.activeTurn,
                            step = closed.activeStep,
                        ),
                    )

                    else -> closed
                }
            }

            is DeviceLiveEvent.UserMessage -> copy(
                items = items + DeviceTranscriptItem(
                    id = id,
                    kind = DeviceItemKind.DEVICE,
                    title = DeviceTranscriptProjector.TITLE_DEVICE,
                    text = event.text,
                    turn = activeTurn,
                ),
            )

            is DeviceLiveEvent.ToolCall -> {
                val closed = finishReasoning().finishAssistant()
                closed.copy(
                    items = closed.items + DeviceTranscriptItem(
                        id = id,
                        kind = DeviceItemKind.TOOL_CALL,
                        title = event.name,
                        text = event.argumentsJson,
                        turn = closed.activeTurn,
                        step = closed.activeStep,
                        callId = event.callId,
                        toolName = event.name,
                        argumentsJson = event.argumentsJson,
                        toolState = DeviceToolState.RUNNING,
                    ),
                )
            }

            is DeviceLiveEvent.ToolResult -> {
                val output = DeviceToolOutput(
                    callId = event.callId,
                    text = event.output,
                    state = when {
                        event.interrupted -> DeviceToolState.STOPPED
                        event.isError -> DeviceToolState.ERROR
                        else -> DeviceToolState.OK
                    },
                )
                val patchable = items.indexOfLast { it.callId == event.callId && isToolRow(it) }
                val alreadyDurable = durable.any { it.callId == event.callId && isToolRow(it) }
                val patched = if (patchable >= 0) {
                    items.toMutableList().also { list ->
                        list[patchable] = list[patchable].copy(
                            outputText = output.text,
                            toolState = output.state,
                        )
                    }
                } else if (alreadyDurable) {
                    // The call row is already on screen from the history window; the
                    // result only patches it (see `applyToolOutputs` at publish time).
                    items
                } else {
                    items + DeviceTranscriptItem(
                        id = id,
                        kind = DeviceItemKind.TOOL_RESULT,
                        title = if (event.isError) {
                            DeviceTranscriptProjector.TITLE_TOOL_ERROR
                        } else {
                            DeviceTranscriptProjector.TITLE_TOOL_RESULT
                        },
                        text = output.text,
                        turn = activeTurn,
                        step = activeStep,
                        callId = event.callId,
                        outputText = output.text,
                        toolState = output.state,
                    )
                }
                copy(items = patched, toolOutputs = toolOutputs + (event.callId to output))
            }

            is DeviceLiveEvent.TurnStarted -> copy(
                activeTurn = event.turnId.toInt(),
                activeStep = null,
            )

            is DeviceLiveEvent.TurnEnded -> finishReasoning().finishAssistant()

            is DeviceLiveEvent.Progress -> copy(
                activeStep = if (event.phase == PHASE_STEP) event.step else activeStep,
            )
        }
    }

    /** Closes every open reasoning row. */
    fun finishReasoning(): DeviceLiveState = copy(
        items = items.map { if (it.kind == DeviceItemKind.REASONING && it.streaming) it.copy(streaming = false) else it },
    )

    /** Closes the open assistant row, if the last row is one. */
    fun finishAssistant(): DeviceLiveState {
        val last = items.lastOrNull() ?: return this
        if (last.kind != DeviceItemKind.ASSISTANT || !last.streaming) return this
        return copy(items = items.dropLast(1) + last.copy(streaming = false))
    }

    private fun appendDelta(
        id: String,
        kind: DeviceItemKind,
        title: String,
        text: String,
        timestampMs: Long?,
        closeReasoning: Boolean = false,
    ): DeviceLiveState {
        val base = if (closeReasoning) finishReasoning() else this
        val last = base.items.lastOrNull()
        if (last != null && last.kind == kind && last.streaming) {
            return base.copy(items = base.items.dropLast(1) + last.copy(text = last.text + text))
        }
        return base.copy(
            items = base.items + DeviceTranscriptItem(
                id = id,
                kind = kind,
                title = title,
                text = text,
                streaming = true,
                timestampMs = timestampMs,
                turn = base.activeTurn,
                step = base.activeStep,
            ),
        )
    }

    private companion object {
        const val PHASE_STEP: String = "step"
    }
}

/**
 * Applies live tool results to a durable projection.
 *
 * A tool result can outrun the history read that publishes its call, so the
 * durable row is patched here rather than left stale behind a finished call.
 */
fun List<DeviceTranscriptItem>.applyToolOutputs(
    outputs: Map<String, DeviceToolOutput>,
): List<DeviceTranscriptItem> {
    if (outputs.isEmpty()) return this
    return map { item ->
        val callId = item.callId ?: return@map item
        if (!isToolRow(item)) return@map item
        val output = outputs[callId] ?: return@map item
        item.copy(outputText = output.text, toolState = output.state)
    }
}

private fun isToolRow(item: DeviceTranscriptItem): Boolean =
    item.kind == DeviceItemKind.TOOL_CALL || item.kind == DeviceItemKind.TOOL_RESULT
