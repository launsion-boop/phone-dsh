// The host half of Agent 预设: `agentPresets/list`, `agentPresets/read` and the
// new-session handoff that carries `request.agentPreset`.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/pages/native-agent-presets.json`; the wire semantics are the
// PR26 iOS `NativeAgentPresetsModel` (iOS HEAD 7f5f092d):
//
//   list  -> args `{}`                 -> `value.presets[]`
//   read  -> args `{agentPreset: id}`  -> `value.content`
//   use   -> `session/create` request  -> `request.agentPreset = id`
//
// The reads run on the IO lane (callers wrap them in `Dispatchers.IO`); a failure
// is never swallowed: the page receives the `DshTurnException` text exactly as
// `code: message`, and an empty answer is a failure, not an empty roster.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshActionReceipt
import com.phonedsh.ui.nav.confirms
import com.phonedsh.ui.page.AgentPresetDocument
import com.phonedsh.ui.page.AgentPresetReadOutcome
import com.phonedsh.ui.page.NativeAgentPreset
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.NativeAgentPresetsScreenState
import com.phonedsh.ui.state.StateRequestId
import kotlinx.coroutines.CancellationException

/** `agentPresets/list` and `agentPresets/read` are management reads, bounded like the others. */
internal const val AGENT_PRESET_READ_TIMEOUT_MILLIS: Long = 5_000L

/**
 * The one failure wording this host shows for any preset read.
 *
 * [DshTurnException] already carries `code: message` in its own `message`; using
 * that value means the page prints the Worker's code unchanged instead of a
 * second, invented sentence. Any other exception keeps its first line so a long
 * stack/message does not become the page copy.
 */
internal fun presetErrorText(failure: Throwable): String = when (failure) {
    is DshTurnException -> failure.message ?: failure.code
    else -> failure.message?.substringBefore('\n')?.take(180)
        ?.takeIf { it.isNotBlank() }
        ?: failure.javaClass.simpleName
}

/** Reads `agentPresets/list` and projects `value.presets[]` into the page facts. */
internal suspend fun readAgentPresets(client: DshTurnClient): NativeAgentPresetsFacts = try {
    val value = client.call(
        "agentPresets/list",
        JsonObject(emptyMap()),
        timeoutMillis = AGENT_PRESET_READ_TIMEOUT_MILLIS,
    )
    NativeAgentPresetsFacts(presets = agentPresetRows(value))
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (failure: Exception) {
    NativeAgentPresetsFacts(error = presetErrorText(failure))
}

/**
 * `value.presets[]` -> roster. A missing array is a failed read, not an empty one:
 * iOS throws `agentPresets/list returned no presets array` instead of telling the
 * page the engine has no presets.
 */
private fun agentPresetRows(value: JsonValue): List<NativeAgentPreset> {
    val root = value as? JsonObject
        ?: throw DshTurnException("invalid_response", "agentPresets/list returned no object")
    val rows = root["presets"] as? JsonArray
        ?: throw DshTurnException("invalid_response", "agentPresets/list returned no presets array")
    return rows.values.mapNotNull(::agentPresetOf)
}

/** One roster row; an id-less row is skipped exactly like iOS's `compactMap`. */
private fun agentPresetOf(value: JsonValue): NativeAgentPreset? {
    val row = value as? JsonObject ?: return null
    val id = row.text("id")?.takeIf { it.isNotBlank() } ?: return null
    return NativeAgentPreset(
        id = id,
        // iOS reads `name`; `title` is accepted as the task's spelling so a
        // Worker that publishes that key is not rendered with the raw id.
        title = row.text("name") ?: row.text("title") ?: id,
        detail = row.text("description") ?: "",
        isDefault = row.bool("isDefault"),
        broken = row.text("broken")?.takeIf { it.isNotBlank() },
        custom = row.bool("custom"),
    )
}

/**
 * `agentPresets/read` with `{agentPreset: id}` -> `value.content`.
 *
 * A missing `content` is [NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE], the
 * baseline's own wording; a wire failure is the Worker's `code: message`.
 */
internal suspend fun readPresetDocument(
    client: DshTurnClient,
    presetId: String,
    title: String,
): AgentPresetReadOutcome = try {
    val value = client.call(
        "agentPresets/read",
        JsonObject(mapOf("agentPreset" to JsonString(presetId))),
        timeoutMillis = AGENT_PRESET_READ_TIMEOUT_MILLIS,
    )
    val content = (value as? JsonObject)?.text("content")
    if (content == null) {
        AgentPresetReadOutcome(failure = NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE)
    } else {
        AgentPresetReadOutcome(
            document = AgentPresetDocument(presetId = presetId, title = title, yaml = content),
        )
    }
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (failure: Exception) {
    AgentPresetReadOutcome(failure = presetErrorText(failure))
}

/** One 使用预设 answer: the new chat's id, or the text the page must show. */
internal data class AgentPresetUseResult(
    val sessionId: String? = null,
    val failure: String? = null,
) {
    val succeeded: Boolean get() = failure == null && sessionId != null
}

/**
 * The 使用预设 transaction: re-read the roster, validate the chosen preset, create
 * the Worker session with `agentPreset`, then create the durable App chat record
 * that owns it.
 *
 * The dependencies are injectable so the JVM suite can drive the real order and
 * the real `DshTurnClient.createSession` while replacing only the durable chat
 * store (which needs the Android app's `DomainStore`). A broken or vanished preset
 * never falls back to an ordinary session: the callback is not called and the
 * page keeps the reason.
 */
internal class AgentPresetSessionLauncher(
    private val readPresets: suspend () -> NativeAgentPresetsFacts,
    private val createWorkerSession: suspend (presetId: String) -> String,
    private val createChatSession: suspend (requestId: StateRequestId, workerSessionId: String) -> PdshActionReceipt,
) {
    suspend fun use(
        presetId: String,
        requestId: StateRequestId,
    ): AgentPresetUseResult {
        val facts = try {
            readPresets()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            return AgentPresetUseResult(failure = presetErrorText(failure))
        }
        facts.error?.let { return AgentPresetUseResult(failure = it) }
        val preset = facts.presets?.firstOrNull { it.id == presetId }
            ?: return AgentPresetUseResult(failure = UiStrings.AGENT_PRESETS_PRESET_GONE)
        preset.broken?.let { return AgentPresetUseResult(failure = it) }

        val workerSessionId = try {
            createWorkerSession(presetId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            return AgentPresetUseResult(failure = presetErrorText(failure))
        }

        val receipt = try {
            createChatSession(requestId, workerSessionId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            return AgentPresetUseResult(failure = presetErrorText(failure))
        }
        if (!receipt.confirms(requestId, receipt.sessionId, null)) {
            return AgentPresetUseResult(failure = UiStrings.AGENT_PRESETS_SESSION_FAILED)
        }
        return AgentPresetUseResult(sessionId = receipt.sessionId)
    }
}

private fun JsonObject.text(name: String): String? = (this[name] as? JsonString)?.value

private fun JsonObject.bool(name: String): Boolean = (this[name] as? JsonBool)?.value == true
