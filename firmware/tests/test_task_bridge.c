// SPDX-License-Identifier: MIT
// Test-only logical Link transport: Swift drives the actual C decoder/state machine.
#define main link_tools_original_main
#include "test_link_tools.c"
#undef main

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c-'0';
    if (c >= 'a' && c <= 'f') return c-'a'+10;
    return -1;
}
int main(void) {
    const char *task="{\"id\":\"task-1\",\"idempotency_key\":\"goal-1\",\"requester\":\"sensor\",\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello from device\"}}";
    tools_init(1); if (!tools_task_submit(task)) return 2;
    char line[9000];
    while (fgets(line,sizeof(line),stdin)) {
        unsigned op; char hex[8500] = {0};
        if (sscanf(line,"%u %8499s",&op,hex)<1) return 3;
        size_t count=strlen(hex); if (count%2) return 4;
        uint8_t body[4200], out[505];
        for (size_t i=0;i<count/2;i++) {
            int a=hexval(hex[i*2]), b=hexval(hex[i*2+1]); if (a<0 || b<0) return 5;
            body[i]=(uint8_t)((a<<4)|b);
        }
        size_t n=0;
        if (op==1) {
            if (count/2!=6) return 7;
            uint32_t caps=(uint32_t)body[2] | (uint32_t)body[3]<<8 | (uint32_t)body[4]<<16 | (uint32_t)body[5]<<24;
            tools_set_task_profile(caps);
            memset(out,0,33); out[1]=2; out[2]=1; out[5]=0x10; out[24]=2;
            memcpy(out+25,"PDSH",4); out[29]=1; out[32]=16; n=33;
        } else if (op==254) {
            cJSON *local=tools_task_result("task-1");
            char *json=local ? cJSON_PrintUnformatted(local) : NULL;
            if (!json || strlen(json)>sizeof(out)) return 6;
            n=strlen(json); memcpy(out,json,n); free(json); cJSON_Delete(local);
        } else {
            n=tools_request((uint8_t)op,body,count/2,out);
            if (op==PDSH_COMMIT && job_fn) run_job();
        }
        for (size_t i=0;i<n;i++) printf("%02x",out[i]);
        putchar('\n'); fflush(stdout);
    }
    return 0;
}
