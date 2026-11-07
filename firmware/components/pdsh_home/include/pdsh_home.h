// SPDX-License-Identifier: MIT
#pragma once
#include "cJSON.h"
#include "xl_home_policy.h"
bool pdsh_home_parse(const cJSON *args, xl_home_request_t *request);
// Blocking, bounded worker operation. Caller must durably reserve the request first.
cJSON *pdsh_home_run(const xl_home_request_t *request, int64_t deadline_us);
