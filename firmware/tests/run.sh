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
  -I"$ROOT/firmware/esp32-reference/main" -I"$CJSON" \
  "$ROOT/firmware/tests/test_task_validate.c" "$ROOT/firmware/esp32-reference/main/pdsh_task_validate.c" \
  "$CJSON/cJSON.c" -o "$OUT/task-validate"
"$OUT/task-validate" "$ROOT/spec/device/v1/golden/task-cases.jsonl" "$ROOT/spec/device/v1/golden/task-raw-json-cases.jsonl" "$ROOT/spec/device/v1/golden/task-raw-bytes.jsonl"
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/esp32-reference/main" -I"$CJSON" \
  "$ROOT/firmware/tests/test_task_store.c" "$ROOT/firmware/esp32-reference/main/pdsh_task_store.c" \
  "$ROOT/firmware/esp32-reference/main/pdsh_task_validate.c" "$CJSON/cJSON.c" -o "$OUT/task-store"
"$OUT/task-store" "$ROOT/spec/device/v1/golden/ble-task-store-cases.jsonl" "$ROOT/spec/device/v1/golden/task-outcome-cases.jsonl"
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -D_DEFAULT_SOURCE -DPDSH_TASK_HOST_TEST -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/components/pdsh_link_wire/include" \
  -I"$ROOT/firmware/esp32-reference/main" -I"$ROOT/firmware/components/pdsh_home/include" \
  -I"$ROOT/firmware/components/pdsh_home/vendor/include" -I"$CJSON" \
  "$ROOT/firmware/tests/test_link_tools.c" "$ROOT/firmware/esp32-reference/main/link_tools.c" \
  "$ROOT/firmware/esp32-reference/main/pdsh_task_store.c" "$ROOT/firmware/esp32-reference/main/pdsh_task_validate.c" \
  "$ROOT/firmware/components/pdsh_link_wire/pdsh_link_wire.c" "$ROOT/firmware/components/pdsh_home/pdsh_home.c" \
  "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" "$CJSON/cJSON.c" -o "$OUT/link-tools" -lm
"$OUT/link-tools"
"$OUT/link-tools" --task
"$OUT/link-tools" --negotiation "$ROOT/spec/device/v1/golden/ble-task-negotiation.jsonl"
"$OUT/link-tools" --plaintext-admission "$ROOT/spec/device/v1/golden/ble-task-plaintext-admission.jsonl"
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -D_DEFAULT_SOURCE -DPDSH_TASK_HOST_TEST -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/components/pdsh_link_wire/include" \
  -I"$ROOT/firmware/esp32-reference/main" -I"$ROOT/firmware/components/pdsh_home/include" \
  -I"$ROOT/firmware/components/pdsh_home/vendor/include" -I"$CJSON" \
  "$ROOT/firmware/tests/test_task_bridge.c" "$ROOT/firmware/esp32-reference/main/link_tools.c" \
  "$ROOT/firmware/esp32-reference/main/pdsh_task_store.c" "$ROOT/firmware/esp32-reference/main/pdsh_task_validate.c" \
  "$ROOT/firmware/components/pdsh_link_wire/pdsh_link_wire.c" "$ROOT/firmware/components/pdsh_home/pdsh_home.c" \
  "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" "$CJSON/cJSON.c" -o "$OUT/task-bridge" -lm
# secure-session-v1 host tests (ble-secure-session.md §13). They drive the real
# firmware C with the shared golden files and a host build of the same
# mbedTLS 4.x / TF-PSA-Crypto sources that ESP-IDF ships. A missing mbedTLS
# source is a failure, never a skip.
MBEDTLS_SRC="${PDSH_MBEDTLS_SRC:-${IDF_PATH:-}/components/mbedtls/mbedtls}"
if [ ! -f "$MBEDTLS_SRC/include/mbedtls/ssl.h" ]; then
  echo "secure-session tests need ESP-IDF's mbedTLS: set IDF_PATH or PDSH_MBEDTLS_SRC" >&2
  exit 1
fi
# §6.1 record cap: the board rejects incoming record plaintext above 4352 bytes
# (CONFIG_MBEDTLS_SSL_IN_CONTENT_LEN on the device, the same define here).
MBEDTLS_DEFS="-DMBEDTLS_SSL_IN_CONTENT_LEN=4352"
MBEDTLS_BUILD="$OUT/mbedtls-host-in4352"
if [ ! -f "$MBEDTLS_BUILD/library/libmbedtls.a" ]; then
  # ESP-IDF's copy includes port headers <mbedtls/bignum.h>/<mbedtls/ecp.h>;
  # on the host they are thin forwards to the upstream private headers.
  mkdir -p "$OUT/mbedtls-shim/mbedtls"
  for h in bignum ecp; do
    printf '#pragma once\n#ifndef MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS\n#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS\n#endif\n#include "mbedtls/private/%s.h"\n' "$h" > "$OUT/mbedtls-shim/mbedtls/$h.h"
  done
  rm -rf "$OUT/mbedtls-src" && cp -a "$MBEDTLS_SRC" "$OUT/mbedtls-src"
  cmake -S "$OUT/mbedtls-src" -B "$MBEDTLS_BUILD" -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-I$OUT/mbedtls-shim $MBEDTLS_DEFS" > "$OUT/mbedtls-cmake.log"
  cmake --build "$MBEDTLS_BUILD" -j8 > "$OUT/mbedtls-build.log"
fi
MBEDTLS_INC=(-I"$OUT/mbedtls-src/include" -I"$OUT/mbedtls-src/tf-psa-crypto/include" \
  -I"$OUT/mbedtls-src/tf-psa-crypto/drivers/builtin/include")
MBEDTLS_LIBS=("$MBEDTLS_BUILD/library/libmbedtls.a" "$MBEDTLS_BUILD/library/libmbedx509.a" \
  "$MBEDTLS_BUILD/library/libtfpsacrypto.a" "$MBEDTLS_BUILD/library/libmbedcrypto.a")
SECURE_CFLAGS=(-std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -D_DEFAULT_SOURCE \
  -fsanitize=address,undefined -fno-sanitize-recover=undefined $MBEDTLS_DEFS "${MBEDTLS_INC[@]}" \
  -I"$ROOT/firmware/tests" -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/esp32-reference/main" -I"$CJSON" \
  -include "$ROOT/firmware/tests/test_secure_support.h")
# The §5 heap budget wraps malloc with GNU ld --wrap; Darwin ld has no such
# option, so there the budget run is NOT_RUN (reported, never PASS) and the
# session test links without tracking.
if [ "$(uname -s)" = Darwin ]; then
  HEAP_LINK=()
  SECURE_CFLAGS+=(-DPDSH_NO_HEAP_WRAP)
else
  HEAP_LINK=(-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free)
fi
MAIN="$ROOT/firmware/esp32-reference/main"
GOLDEN="$ROOT/spec/device/v1/golden"
cc "${SECURE_CFLAGS[@]}" "$ROOT/firmware/tests/test_secure_task_store.c" "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" "${MBEDTLS_LIBS[@]}" -o "$OUT/task-store-v2"
"$OUT/task-store-v2" "$GOLDEN/ble-secure-task-store-cases.jsonl"

cc "${SECURE_CFLAGS[@]}" "$ROOT/firmware/tests/test_secure_enroll.c" "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_enroll.c" "$MAIN/pdsh_secure_msg.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" \
  "${MBEDTLS_LIBS[@]}" -o "$OUT/secure-enroll"
"$OUT/secure-enroll" "$GOLDEN/ble-secure-enrollment-lines.jsonl" "$GOLDEN/ble-secure-enrollment-states.jsonl"
bash "$ROOT/firmware/tests/check_enroll_stack.sh"
cc "${SECURE_CFLAGS[@]}" "$ROOT/firmware/tests/test_secure_session.c" "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_secure_session.c" "$MAIN/pdsh_secure_msg.c" "$MAIN/pdsh_secure_cert.c" "$MAIN/pdsh_enroll.c" \
  "$MAIN/pdsh_identity.c" "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" \
  "${MBEDTLS_LIBS[@]}" ${HEAP_LINK[@]+"${HEAP_LINK[@]}"} -o "$OUT/secure-session"
"$OUT/secure-session" --identifiers "$GOLDEN/ble-secure-identifiers.jsonl" \
  --certificates "$GOLDEN/ble-secure-certificates.jsonl" --frames "$GOLDEN/ble-secure-frames.jsonl" \
  --messages "$GOLDEN/ble-secure-messages.jsonl" --sequences "$GOLDEN/ble-secure-session-sequences.jsonl"
cc "${SECURE_CFLAGS[@]}" "$ROOT/firmware/tests/test_secure_coc.c" "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_secure_session.c" "$MAIN/pdsh_secure_msg.c" "$MAIN/pdsh_secure_cert.c" "$MAIN/pdsh_enroll.c" \
  "$MAIN/pdsh_identity.c" "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" \
  "${MBEDTLS_LIBS[@]}" -o "$OUT/secure-coc"
"$OUT/secure-coc" "$GOLDEN/ble-secure-coc-cases.jsonl"
cc -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -D_DEFAULT_SOURCE -DPDSH_TASK_HOST_TEST -fsanitize=address,undefined \
  -I"$ROOT/firmware/tests/stubs" -I"$ROOT/firmware/components/pdsh_link_wire/include" \
  -I"$ROOT/firmware/esp32-reference/main" -I"$ROOT/firmware/components/pdsh_home/include" \
  -I"$ROOT/firmware/components/pdsh_home/vendor/include" -I"$CJSON" -I"$ROOT/firmware/tests" \
  "$ROOT/firmware/tests/test_secure_board.c" "$MAIN/link_tools.c" \
  "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" \
  "$ROOT/firmware/components/pdsh_link_wire/pdsh_link_wire.c" "$ROOT/firmware/components/pdsh_home/pdsh_home.c" \
  "$ROOT/firmware/components/pdsh_home/vendor/xl_home_policy.c" "$CJSON/cJSON.c" -o "$OUT/secure-board" -lm
"$OUT/secure-board"
# Cross-runtime conformance: the real board end as a host process, driven by
# the real Swift client (Tests/PhoneDSHBLETests/BLESecureCrossRuntimeTests).
cc "${SECURE_CFLAGS[@]}" "$ROOT/firmware/tests/test_secure_bridge.c" "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_secure_session.c" "$MAIN/pdsh_secure_msg.c" "$MAIN/pdsh_secure_cert.c" "$MAIN/pdsh_enroll.c" \
  "$MAIN/pdsh_identity.c" "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" \
  "${MBEDTLS_LIBS[@]}" -o "$OUT/secure-bridge"
if [ "$(uname -s)" = Darwin ]; then
  echo "secure-session heap budget (<= 32 KiB per session): NOT_RUN on Darwin (needs GNU ld --wrap; run on Linux)"
  exit 0
fi
# Heap budget at the device buffer sizes (§5 <= 32 KiB per session): the same
# session test against a host mbedTLS built with the device's 4352/4096 record
# buffers (the overflow row needs the default build above and is skipped here).
MBEDTLS_DEV_BUILD="$OUT/mbedtls-host-in4352-out4096"
if [ ! -f "$MBEDTLS_DEV_BUILD/library/libmbedtls.a" ]; then
  cmake -S "$OUT/mbedtls-src" -B "$MBEDTLS_DEV_BUILD" -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="-I$OUT/mbedtls-shim $MBEDTLS_DEFS -DMBEDTLS_SSL_OUT_CONTENT_LEN=4096" \
    > "$OUT/mbedtls-dev-cmake.log"
  cmake --build "$MBEDTLS_DEV_BUILD" -j8 > "$OUT/mbedtls-dev-build.log"
fi
cc "${SECURE_CFLAGS[@]}" -DMBEDTLS_SSL_OUT_CONTENT_LEN=4096 -DPDSH_HEAP_PROFILE "$ROOT/firmware/tests/test_secure_session.c" \
  "$ROOT/firmware/tests/test_secure_support.c" \
  "$MAIN/pdsh_secure_session.c" "$MAIN/pdsh_secure_msg.c" "$MAIN/pdsh_secure_cert.c" "$MAIN/pdsh_enroll.c" \
  "$MAIN/pdsh_identity.c" "$MAIN/pdsh_task_store.c" "$MAIN/pdsh_task_validate.c" "$CJSON/cJSON.c" \
  "$MBEDTLS_DEV_BUILD/library/libmbedtls.a" "$MBEDTLS_DEV_BUILD/library/libmbedx509.a" \
  "$MBEDTLS_DEV_BUILD/library/libtfpsacrypto.a" "$MBEDTLS_DEV_BUILD/library/libmbedcrypto.a" \
  "${HEAP_LINK[@]}" -o "$OUT/secure-session-heap"
"$OUT/secure-session-heap" --heap-only --identifiers "$GOLDEN/ble-secure-identifiers.jsonl" \
  --certificates "$GOLDEN/ble-secure-certificates.jsonl" --frames "$GOLDEN/ble-secure-frames.jsonl" \
  --messages "$GOLDEN/ble-secure-messages.jsonl" --sequences "$GOLDEN/ble-secure-session-sequences.jsonl"
