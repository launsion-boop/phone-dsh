// SPDX-License-Identifier: MIT
package com.phonedsh.ui.nav

import com.phonedsh.ui.page.AutomationScheduleDraft
import com.phonedsh.ui.page.ProviderDraft
import com.phonedsh.ui.state.PendingAnswer
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision

/** Why a host cannot currently perform a routed action. */
public enum class PdshUnavailableReason {
    /** The host has no implementation for this operation. */
    NOT_IMPLEMENTED,
    /** The host implementation exists, but its required service is disconnected. */
    DISCONNECTED,
    /** A required fact or identifier is not currently known. */
    REQUIRED_FACT_UNKNOWN,
    /** The operation is temporarily blocked by another operation. */
    BUSY,
    /** The operation is not permitted in the current session or platform. */
    NOT_PERMITTED,
    /** A callback was offered a request from a different action family. */
    INVALID_REQUEST,
}

/** An operation is either backed by its real host callback or unavailable. */
public sealed interface PdshActionAvailability<out Callback> {
    /** The host supplied the callback that performs this operation. */
    public data class Available<Callback>(public val callback: Callback) : PdshActionAvailability<Callback>

    /** No callback can perform this operation; UI must keep it unavailable. */
    public data class Unavailable(public val reason: PdshUnavailableReason) : PdshActionAvailability<Nothing>
}

/** Names every action surface whose availability is reported by the host. */
public enum class PdshActionKey {
    NEW_SESSION, OPEN_SCHEDULES, OPEN_SETTINGS, SELECT_MODEL, SELECT_PERMISSION_MODE,
    SEND, QUEUE, QUEUE_EDIT, QUEUE_REMOVE, QUEUE_STEER, STEER, STOP, RETRY, ANSWER_QUESTION, DISCARD_QUESTION,
    APPROVE_PLAN, REJECT_PLAN, GOAL_PAUSE, GOAL_RESUME, GOAL_CLEAR, EXECUTE_COMMAND,
    PROVIDER_EDITOR, PROVIDER_GET_MODELS, PROVIDER_TEST, PROVIDER_SAVE, PROVIDER_DELETE,
    SCHEDULE_CATALOG, SCHEDULE_CREATE, SCHEDULE_UPDATE, SCHEDULE_DELETE, SCHEDULE_HISTORY,
    WORKSPACE_FOLDER_CREATE, WORKSPACE_FOLDER_RENAME, WORKSPACE_FOLDER_DELETE,
    SESSION_RENAME, SESSION_ARCHIVE, SESSION_RESTORE, SESSION_DELETE, SEARCH,
    ARCHIVED_SESSIONS, ARTIFACT_OPEN, ARTIFACT_SHARE, FILE_IMPORT, SAF_IMPORT,
    DEVICE_CONNECT, DEVICE_SESSION, EXPORT_TRANSCRIPT, IMAGE_IMPORT, RUNTIME_RESTART,
    RUNTIME_STOP, ENGINE_RESET, LOCALE_READ, LOCALE_WRITE, FONT_SIZE_READ,
    FONT_SIZE_WRITE, FONT_FAMILY_READ, FONT_FAMILY_WRITE, LICENSE_CATALOG, SPEAK_RECENT_REPLY, SHELL_CANCEL,
}

/** One typed request family; every mutating request carries the caller's request id. */
public sealed interface PdshUiHostCommand {
    /** The exact availability key required to dispatch this command. */
    public val actionKey: PdshActionKey

    /** Start a new session in the host-selected workspace. */
    public data class NewSession(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.NEW_SESSION
    }
    /** Navigate to the schedules catalog. */
    public data object OpenSchedules : PdshUiHostCommand { override val actionKey = PdshActionKey.OPEN_SCHEDULES }
    /** Navigate to settings. */
    public data object OpenSettings : PdshUiHostCommand { override val actionKey = PdshActionKey.OPEN_SETTINGS }
    /** Select a model from a host-reported model catalog. */
    public data class SelectModel(public val model: String, public val effort: String?, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SELECT_MODEL
    }
    /** Select a permission mode from the host-reported catalog. */
    public data class SelectPermissionMode(public val modeId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SELECT_PERMISSION_MODE
    }
    /** Send a message to an idle session. */
    public data class Send(public val sessionId: String, public val requestId: StateRequestId, public val text: String) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SEND
    }
    /** Durably queue a message for a session. */
    public data class Queue(public val sessionId: String, public val requestId: StateRequestId, public val text: String) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.QUEUE
    }
    /** Steer the active turn. */
    public data class Steer(public val sessionId: String, public val requestId: StateRequestId, public val text: String) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.STEER
    }
    /** Stop the exact active turn. */
    public data class Stop(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.STOP
    }
    /** Retry the exact failed request. */
    public data class Retry(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.RETRY
    }
    /** Edit a durable queue item by host id. */
    public data class EditQueueItem(public val sessionId: String, public val itemId: String, public val requestId: StateRequestId, public val text: String) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.QUEUE_EDIT
    }
    /** Remove a durable queue item by host id. */
    public data class RemoveQueueItem(public val sessionId: String, public val itemId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.QUEUE_REMOVE
    }
    /** Steer one durable queue item, preserving its host identity. */
    public data class SteerQueueItem(public val sessionId: String, public val itemId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.QUEUE_STEER
    }
    /** Cancel the named queued or in-flight request. */
    public data class CancelRequest(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.STOP
    }
    /** Answer the exact pending question/permission request. */
    public data class AnswerQuestion(public val sessionId: String, public val pending: PendingAnswer, public val requestId: StateRequestId, public val answer: String) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.ANSWER_QUESTION
    }
    /** Discard the exact pending question. */
    public data class DiscardQuestion(public val sessionId: String, public val pending: PendingAnswer, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.DISCARD_QUESTION
    }
    /** Approve the exact pending plan. */
    public data class ApprovePlan(
        public val sessionId: String,
        public val planRequestId: StateRequestId,
        public val requestId: StateRequestId,
        /** Existing source wire JSON built from the exact pending plan question. */
        public val answer: String,
    ) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.APPROVE_PLAN
    }
    /** Reject the exact pending plan. */
    public data class RejectPlan(public val sessionId: String, public val planRequestId: StateRequestId, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.REJECT_PLAN
    }
    /** Pause, resume, or clear the identified goal. */
    public data class Goal(public val sessionId: String, public val goalId: String, public val operation: GoalOperation, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = when (operation) {
            GoalOperation.PAUSE -> PdshActionKey.GOAL_PAUSE
            GoalOperation.RESUME -> PdshActionKey.GOAL_RESUME
            GoalOperation.CLEAR -> PdshActionKey.GOAL_CLEAR
        }
    }
    /** Closed set of goal operations supported by this contract. */
    public enum class GoalOperation { PAUSE, RESUME, CLEAR }
    /** Run one command with argv-like fields supplied by the shell surface. */
    public data class ExecuteCommand(public val command: String, public val workingDirectory: String, public val arguments: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.EXECUTE_COMMAND
    }
    /** Cancel one exact read-only accelerator execution by its execution id. */
    public data class ShellCancel(public val execId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SHELL_CANCEL
    }
    /** Open a provider editor for an existing profile or a new profile. */
    public data class OpenProviderEditor(public val profileId: String?) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.PROVIDER_EDITOR
    }
    /** Fetch available models for one provider draft. */
    public data class ProviderGetModels(public val draft: ProviderDraft, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.PROVIDER_GET_MODELS
    }
    /** Test one provider draft; result must be bound to this request id. */
    public data class ProviderTest(public val draft: ProviderDraft, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.PROVIDER_TEST
    }
    /** Save one provider draft; result must be bound to this request id. */
    public data class ProviderSave(public val draft: ProviderDraft, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.PROVIDER_SAVE
    }
    /** Delete one provider profile. */
    public data class ProviderDelete(public val profileId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.PROVIDER_DELETE
    }
    /** Refresh the schedule catalog. */
    public data class ScheduleCatalog(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SCHEDULE_CATALOG
    }
    /** Create a schedule and require a matching write/read receipt. */
    public data class ScheduleCreate(public val draft: AutomationScheduleDraft, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SCHEDULE_CREATE
    }
    /** Update a schedule and require a matching write/read receipt. */
    public data class ScheduleUpdate(public val scheduleId: String, public val draft: AutomationScheduleDraft, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SCHEDULE_UPDATE
    }
    /** Delete a schedule and require a matching write/read receipt. */
    public data class ScheduleDelete(public val scheduleId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SCHEDULE_DELETE
    }
    /** Read schedule delivery history. */
    public data class ScheduleHistory(public val scheduleId: String, public val cursor: String?, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SCHEDULE_HISTORY
    }
    /** Create a workspace folder. */
    public data class WorkspaceFolderCreate(public val name: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.WORKSPACE_FOLDER_CREATE
    }
    /** Rename a workspace folder. */
    public data class WorkspaceFolderRename(public val folderId: String, public val name: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.WORKSPACE_FOLDER_RENAME
    }
    /** Delete a workspace folder. */
    public data class WorkspaceFolderDelete(public val folderId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.WORKSPACE_FOLDER_DELETE
    }
    /** Rename a session. */
    public data class SessionRename(public val sessionId: String, public val title: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SESSION_RENAME
    }
    /** Archive a session, requiring an explicit matching host receipt. */
    public data class SessionArchive(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SESSION_ARCHIVE
    }
    /** Restore a session, requiring an explicit matching host receipt. */
    public data class SessionRestore(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SESSION_RESTORE
    }
    /** Delete a session. */
    public data class SessionDelete(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SESSION_DELETE
    }
    /** Search the host-owned readable index. */
    public data class Search(public val query: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SEARCH
    }
    /** Read archived sessions. */
    public data class ArchivedSessions(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.ARCHIVED_SESSIONS
    }
    /** Open an artifact at its original host URI. */
    public data class ArtifactOpen(public val artifactId: String, public val originalUri: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.ARTIFACT_OPEN
    }
    /** Share an artifact at its original host URI. */
    public data class ArtifactShare(public val artifactId: String, public val originalUri: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.ARTIFACT_SHARE
    }
    /** Start platform file import. */
    public data class FileImport(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FILE_IMPORT
    }
    /** Start image-only SAF import for the conversation composer. */
    public data class ImageImport(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.IMAGE_IMPORT
    }
    /** Start Android SAF file import. */
    public data class SafImport(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SAF_IMPORT
    }
    /** Cancel an active platform file import. */
    public data class FileImportCancel(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FILE_IMPORT
    }
    /** Connect to the selected device. */
    public data class DeviceConnect(public val deviceId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.DEVICE_CONNECT
    }
    /** Open a specific session on a device. */
    public data class DeviceSession(public val deviceId: String, public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.DEVICE_SESSION
    }
    /** Export a transcript for the named session. */
    public data class ExportTranscript(public val sessionId: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.EXPORT_TRANSCRIPT
    }
    /** Speak one host-provided assistant reply through the device's actual TTS engine. */
    public data class SpeakRecentReply(
        public val sessionId: String,
        public val requestId: StateRequestId,
        public val text: String,
    ) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.SPEAK_RECENT_REPLY
    }
    /** Restart the runtime. */
    public data class RuntimeRestart(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.RUNTIME_RESTART
    }
    /** Stop the runtime. */
    public data class RuntimeStop(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.RUNTIME_STOP
    }
    /** Reset the engine. */
    public data class EngineReset(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.ENGINE_RESET
    }
    /** Set a locale preference. */
    public data class LocaleWrite(public val localeTag: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.LOCALE_WRITE
    }
    /** Re-read the host's locale preference. */
    public data class LocaleRead(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.LOCALE_READ
    }
    /** Set a font size preference. */
    public data class FontSizeWrite(public val size: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FONT_SIZE_WRITE
    }
    /** Re-read the host's font-size preference. */
    public data class FontSizeRead(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FONT_SIZE_READ
    }
    /** Set a font family preference. */
    public data class FontFamilyWrite(public val family: String, public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FONT_FAMILY_WRITE
    }
    /** Re-read the host's font-family preference. */
    public data class FontFamilyRead(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.FONT_FAMILY_READ
    }
    /** Read the actual license catalog; unknown remains a host read result. */
    public data class LicenseCatalogRead(public val requestId: StateRequestId) : PdshUiHostCommand {
        override val actionKey = PdshActionKey.LICENSE_CATALOG
    }
}

/** The one authoritative availability table; omitted actions are unavailable. */
public data class PdshActionAvailabilities(
    /** Real callbacks by action key. Missing keys are not available. */
    public val byAction: Map<PdshActionKey, PdshActionAvailability<(PdshUiHostCommand) -> Unit>> = emptyMap(),
) {
    /** Returns action support, treating an omitted key as unavailable. */
    public fun forAction(action: PdshActionKey): PdshActionAvailability<(PdshUiHostCommand) -> Unit> =
        byAction[action] ?: PdshActionAvailability.Unavailable(PdshUnavailableReason.NOT_IMPLEMENTED)

    /** Dispatches a matching typed request only when a real callback exists. */
    public fun dispatch(action: PdshActionKey, request: PdshUiHostCommand): Boolean {
        if (request.actionKey != action) return false
        return when (val availability = forAction(action)) {
            is PdshActionAvailability.Available -> { availability.callback(request); true }
            is PdshActionAvailability.Unavailable -> false
        }
    }
}

/** Host response bound to the request, session, and read revision that produced it. */
public data class PdshActionReceipt(
    /** Exact caller-supplied id of the action request. */
    public val requestId: StateRequestId,
    /** Session that owned the request; null only for non-session operations. */
    public val sessionId: String?,
    /** Host revision observed after the operation; absent means success is unconfirmed. */
    public val revision: StateRevision?,
    /** Explicit host outcome; callback invocation alone is not a success receipt. */
    public val outcome: PdshActionOutcome,
)

/** Explicit terminal result returned by the host. */
public enum class PdshActionOutcome { SUCCEEDED, FAILED }

/** A receipt settles a pending request only for the same request/session and newer read. */
public fun PdshActionReceipt.confirms(expectedRequestId: StateRequestId, expectedSessionId: String?, minimumRevision: StateRevision?): Boolean =
    requestId == expectedRequestId && sessionId == expectedSessionId && outcome == PdshActionOutcome.SUCCEEDED &&
        revision != null && (minimumRevision == null || revision > minimumRevision)

/** One provider get-models/test/save result read back from the host. */
public data class PdshProviderOperationFact(
    /** Operation whose result this fact belongs to. */
    public val operation: PdshProviderOperation,
    /** Exact caller-supplied request identity. */
    public val requestId: StateRequestId,
    /** Profile identity; null only while creating a new profile. */
    public val profileId: String?,
    /** Host receipt; absent means the operation has not been confirmed. */
    public val receipt: PdshActionReceipt?,
    /** Read model catalog; null means no result was reported, empty means read and empty. */
    public val models: List<String>? = null,
    /** Safe host-reported diagnostic; must not contain a credential. */
    public val message: String? = null,
)

/** Model-service operations that produce request-correlated results. */
public enum class PdshProviderOperation { GET_MODELS, TEST, SAVE }

/** Confirms only when request, profile, operation, and host receipt all match. */
public fun PdshProviderOperationFact.confirms(expectedOperation: PdshProviderOperation, expectedRequestId: StateRequestId, expectedProfileId: String?, minimumRevision: StateRevision?): Boolean =
    operation == expectedOperation && requestId == expectedRequestId && profileId == expectedProfileId &&
        receipt?.confirms(expectedRequestId, null, minimumRevision) == true
