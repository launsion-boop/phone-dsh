// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include "cJSON.h"
#include "nvs.h"

bool pdsh_task_store_init(nvs_handle_t storage);
void pdsh_task_store_disable(void);
bool pdsh_task_store_healthy(void);
bool pdsh_task_store_submit(const char *json);
cJSON *pdsh_task_store_next(void);
cJSON *pdsh_task_store_result(const char *id);
bool pdsh_task_store_transition(const char *action, const cJSON *args);
