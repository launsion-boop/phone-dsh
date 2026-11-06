// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include "cJSON.h"
// Validate the shared device-task contract before retaining or dispatching it.
bool pdsh_task_validate_json(const char *json);
bool pdsh_task_validate(const cJSON *task);
bool pdsh_task_json_no_nul(const char *json);
bool pdsh_task_valid_output(const char *text, size_t max_bytes);
