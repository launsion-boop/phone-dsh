// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include "cJSON.h"
#include "nvs.h"

/* Reference task store v2 (ble-secure-session.md §10). NVS key tasks_v2 in the
 * task namespace; a valid tasks_v1 is migrated in memory and written as v2 by
 * the first mutation, leaving tasks_v1 byte-identical. */
typedef enum {
    PDSH_STORE_SOURCE_DISABLED,
    PDSH_STORE_SOURCE_EMPTY,
    PDSH_STORE_SOURCE_V2,
    PDSH_STORE_SOURCE_V1_MIGRATED,
} pdsh_task_store_source_t;

bool pdsh_task_store_init(nvs_handle_t storage);
pdsh_task_store_source_t pdsh_task_store_source(void);
void pdsh_task_store_disable(void);
bool pdsh_task_store_healthy(void);
/* Local producer API (unchanged semantics, v2 storage). */
bool pdsh_task_store_submit(const char *json);
cJSON *pdsh_task_store_result(const char *id);
/* Owned copy of the slot array (v2 view) or NULL when disabled. */
cJSON *pdsh_task_store_view(void);

/* Legacy owner-less Link task core. Reachable only from the host-test target
 * core; the ordinary Link ingress refuses pdsh.task.* permanently (§11.2). */
cJSON *pdsh_task_store_next(void);
bool pdsh_task_store_transition(const char *action, const cJSON *args);

/* Secure-session transitions (§9.1). owner is the session's "phone:" ID. */
typedef enum {
    PDSH_STORE_APPLIED,
    PDSH_STORE_DUPLICATE,
    PDSH_STORE_UNKNOWN_TASK,
    PDSH_STORE_CONFLICT,
    PDSH_STORE_WRONG_OWNER,
    PDSH_STORE_INVALID_TRANSITION,
    PDSH_STORE_FAILED, /* storage failure or store disabled: slot unchanged */
} pdsh_store_result_t;
/* Returns {task, phase} for the oldest slot queued or accepted by owner,
 * or {task:null, phase:null}; NULL when disabled or out of memory. */
cJSON *pdsh_task_store_offer(const char *owner);
/* action: "accept", "complete" (outcome {output,truncated}) or "fail"
 * (outcome {failure}). *phase receives the phase after the request. */
pdsh_store_result_t pdsh_task_store_secure(const char *action, const char *id, const char *idem,
                                           const char *owner, const cJSON *outcome,
                                           const char **phase);
/* status: *phase "unknown" for an unknown id; CONFLICT on key mismatch.
 * *outcome is an owned copy only when terminal and mine. */
pdsh_store_result_t pdsh_task_store_status(const char *id, const char *idem, const char *owner,
                                           const char **phase, bool *mine, cJSON **outcome);
