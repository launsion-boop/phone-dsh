// SPDX-License-Identifier: MIT
#pragma once
#include <stdbool.h>
#include "cJSON.h"
// Validate the shared device-task contract before retaining or dispatching it.
bool pdsh_task_validate_json(const char *json);
bool pdsh_task_validate(const cJSON *task);
