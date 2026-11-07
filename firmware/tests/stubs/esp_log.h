// SPDX-License-Identifier: MIT
#pragma once
// Host fixtures do not use the ESP logging runtime.
#define ESP_LOGW(tag, ...) ((void)(tag))
