// SPDX-License-Identifier: MIT
/* secure-board: matrix row board-identity-prove-retired through the real
 * link_tools.c ingress (ble-secure-session.md §11.3). Reuses the controlled
 * Link harness of test_link_tools.c. */
#define main link_tools_original_main
#include "test_link_tools.c"
#undef main

int main(void) {
    uint8_t out[505];
    int state;
    identity_ready = true;
    tools_init(1);
    tools_set_secure_service(true);
    tools_reset_upload();
    tools_set_task_profile(PDSH_APP_TOOLS | PDSH_APP_TASKS);
    assert(submit(100, "tools/list", "{}", "discover", out) == 0);
    cJSON *reply = query(100, &state);
    cJSON *list = cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(reply, "result"), "tools");
    assert(state == 2 && cJSON_IsArray(list) && !has_tool(list, "pdsh.identity.prove"));
    cJSON_Delete(reply);
    entry_t snapshot[40];
    memcpy(snapshot, disk, sizeof(snapshot));
    int before = identity_proofs;
    assert(submit(101, "pdsh.identity.prove", "{\"nonce\":\"test-nonce\"}", "prove", out) == 14);
    assert(identity_proofs == before && !job_fn && !staged && memcmp(snapshot, disk, sizeof(snapshot)) == 0);
    assert(query(101, &state) == NULL && state == 0);
    /* Control: without the secure service the legacy diagnostic still works. */
    tools_set_secure_service(false);
    tools_reset_upload();
    tools_set_task_profile(PDSH_APP_TOOLS | PDSH_APP_TASKS);
    assert(submit(102, "pdsh.identity.prove", "{\"nonce\":\"test-nonce\"}", "prove2", out) == 0);
    assert(identity_proofs == before + 1);
    puts("board-identity-prove-retired (host): not listed, call -> UNSUPPORTED 14, no receipt, no signature PASS");
    return 0;
}
