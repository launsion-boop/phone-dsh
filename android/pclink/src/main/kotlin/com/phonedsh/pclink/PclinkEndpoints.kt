// SPDX-License-Identifier: MIT
// Normative `workspace/1` endpoint inventory and retry classes (§7).
//
// `spec/pclink/v1/endpoints.json` is the authority. An app bundle cannot read
// the repository at runtime, so the table is embedded here; the JVM test
// re-reads `endpoints.json` from disk and proves every row matches exactly.
// The inventory is for retry classification and version compatibility only:
// PCLink v1 has no endpoint allowlist, an endpoint missing here is still
// forwarded and is treated as `unsafe` for retry purposes.
package com.phonedsh.pclink

enum class PclinkRetryClass { READ, IDEMPOTENT, UNSAFE }

enum class PclinkEndpointKind { UNARY, STREAM }

data class PclinkEndpointSpec(
    val kind: PclinkEndpointKind,
    val retry: PclinkRetryClass,
    val phoneOnly: Boolean,
)

object PclinkEndpoints {
    const val SUITE = "workspace/1"
    const val DSH_TESTED_RANGE = ">=0.2.2-rc.1 <0.3.0"
    val DEFAULT_RETRY: PclinkRetryClass = PclinkRetryClass.UNSAFE
    const val FORBIDDEN_REMOTE_PREFIX = "pclink.admin/"

    /** The 57 rows of `endpoints.json`, in file order. */
    val inventory: Map<String, PclinkEndpointSpec> = linkedMapOf(
        "\$events" to PclinkEndpointSpec(PclinkEndpointKind.STREAM, PclinkRetryClass.READ, false),
        "\$events/result" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "agentPresets/list" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "agentPresets/read" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "commands/execute" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "commands/list" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "goals/complete" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "goals/get" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "goals/pause" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "goals/resume" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "job/kill" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "job/list" to PclinkEndpointSpec(PclinkEndpointKind.STREAM, PclinkRetryClass.READ, false),
        "messageFeedback/put" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "permissionPresets/catalog" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "phone/botClaimSession" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/createSchedule" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/importAbort" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/importBegin" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/importCommit" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/importWrite" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/listTools" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, true),
        "phone/mcpList" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, true),
        "phone/mcpReconnect" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/mcpRemove" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/mcpUpsert" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, true),
        "phone/pluginList" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, true),
        "pluginInventory/list" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "schedule/catalog" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "schedule/edit" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "schedule/history" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/cancel" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "session/create" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "session/follow" to PclinkEndpointSpec(PclinkEndpointKind.STREAM, PclinkRetryClass.READ, false),
        "session/fork" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "session/list" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/modelCatalog" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/page" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/prompt" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "session/projections" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/rename" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "session/search" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "session/selectModel" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "session/updateQueue" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "settings/describe" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "settings/mutate" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "settings/update" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "skills/list" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.READ, false),
        "subagents/interruptByParent" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "workspace/archiveSession" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "workspace/create" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "workspace/delete" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.UNSAFE, false),
        "workspace/follow" to PclinkEndpointSpec(PclinkEndpointKind.STREAM, PclinkRetryClass.READ, false),
        "workspace/insertSessionBefore" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "workspace/pinSession" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "workspace/rename" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "workspace/unarchiveSession" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
        "workspace/unpinSession" to PclinkEndpointSpec(PclinkEndpointKind.UNARY, PclinkRetryClass.IDEMPOTENT, false),
    )

    fun specFor(endpoint: String): PclinkEndpointSpec? = inventory[endpoint]

    fun retryClass(endpoint: String): PclinkRetryClass =
        inventory[endpoint]?.retry ?: DEFAULT_RETRY

    /**
     * The one forbidden remote endpoint prefix (§6.1). Admin routes are not a
     * general allowlist; every other endpoint is forwarded.
     */
    fun isForbiddenRemoteAdmin(endpoint: String): Boolean =
        endpoint.startsWith(FORBIDDEN_REMOTE_PREFIX)
}
