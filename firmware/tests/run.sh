#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.build/link-host"
mkdir -p "$OUT"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I"$ROOT/firmware/components/pdsh_link_wire/include" \
  "$ROOT/firmware/tests/test_link_wire.c" "$ROOT/firmware/components/pdsh_link_wire/pdsh_link_wire.c" -o "$OUT/link-wire"
"$OUT/link-wire"
"$OUT/link-wire" --vectors > "$OUT/pdsh-link.jsonl"
cmp "$OUT/pdsh-link.jsonl" "$ROOT/spec/device/v1/golden/pdsh-link.jsonl"
"$OUT/link-wire" --verify "$ROOT/spec/device/v1/golden/pdsh-link.jsonl" valid
"$OUT/link-wire" --verify "$ROOT/spec/device/v1/golden/xiaozhi-ctl.jsonl" valid
"$OUT/link-wire" --verify "$ROOT/spec/device/v1/golden/invalid-ctl.jsonl" invalid
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I"$ROOT/firmware/components/pdsh_home/vendor/include" \
  "$ROOT/firmware/tests/test_home_policy.c" "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" -o "$OUT/home-policy"
cc -std=c11 -Wall -Wextra -Werror -O1 -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/transport/stubs" -I"$ROOT/firmware/components/pdsh_home/vendor/include" \
  "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" \
  "$ROOT/firmware/tests/transport/test_home_transport.c" -o "$OUT/home-transport"
"$OUT/home-transport"
"$OUT/home-policy"
if [ "${1:-}" = "--portable-only" ]; then
  exit 0
fi
CJSON="$ROOT/firmware/esp32-reference/managed_components/espressif__cjson/cJSON"
if [ ! -f "$CJSON/cJSON.c" ]; then
  echo "Run the ESP-IDF reference firmware build first to resolve the pinned cJSON component." >&2
  exit 1
fi
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/components/pdsh_link_wire/include" \
  -I"$ROOT/firmware/esp32-reference/main" -I"$ROOT/firmware/components/pdsh_home/include" \
  -I"$ROOT/firmware/components/pdsh_home/vendor/include" -I"$CJSON" \
  "$ROOT/firmware/tests/test_link_tools.c" "$ROOT/firmware/esp32-reference/main/link_tools.c" \
  "$ROOT/firmware/components/pdsh_link_wire/pdsh_link_wire.c" "$ROOT/firmware/components/pdsh_home/pdsh_home.c" \
  "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" "$CJSON/cJSON.c" -o "$OUT/link-tools"
"$OUT/link-tools"
