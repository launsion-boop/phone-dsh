// SPDX-License-Identifier: MIT
#include "pdsh_task_validate.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static void reject_numeric_known_fields(void) {
    const char *task="{\"id\":\"task-1\",\"idempotency_key\":\"key-1\",\"requester\":\"sensor\","
                     "\"created_at\":\"2026-11-06T00:00:00Z\",\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}";
    const char *targets[]={"\"task-1\"","\"key-1\"","\"sensor\"","\"2026-11-06T00:00:00Z\"",
                           "\"goal\"","\"Hello\"","{\"type\":\"goal\",\"text\":\"Hello\"}"};
    assert(pdsh_task_validate_json(task));
    for (size_t i=0;i<sizeof(targets)/sizeof(targets[0]);i++) {
        const char *at=strstr(task,targets[i]); assert(at);
        char changed[1024];
        int n=snprintf(changed,sizeof(changed),"%.*s123%s",(int)(at-task),task,at+strlen(targets[i]));
        assert(n>0 && (size_t)n<sizeof(changed));
        assert(!pdsh_task_validate_json(changed));
    }
    assert(!pdsh_task_validate_json("{\"id\":\"task-1\",\"idempotency_key\":\"key-1\",\"requester\":\"sensor\","
                                    "\"created_at\":\"2026-11-06T00:00:00Z\",\"deadline\":123,"
                                    "\"body\":{\"type\":\"goal\",\"text\":\"Hello\"}}"));
}

int main(int argc, char **argv) {
    assert(argc == 4);
    reject_numeric_known_fields();
    FILE *file = fopen(argv[1], "rb"); assert(file);
    char line[16384]; int count = 0;
    while (fgets(line, sizeof(line), file)) {
        cJSON *row = cJSON_Parse(line); assert(row);
        const cJSON *valid = cJSON_GetObjectItemCaseSensitive(row, "valid");
        const cJSON *name = cJSON_GetObjectItemCaseSensitive(row, "name");
        assert(cJSON_IsBool(valid) && cJSON_IsString(name));
        char *task = strstr(line, "\"task\":"); assert(task); task += strlen("\"task\":");
        size_t n = strlen(task); while (n && (task[n-1] == '\n' || task[n-1] == '\r')) task[--n] = 0;
        assert(n > 0 && task[n-1] == '}'); task[--n] = 0;
        bool got = pdsh_task_validate_json(task), expected = cJSON_IsTrue(valid);
        if (got != expected) { fprintf(stderr, "task vector mismatch: %s\n", name->valuestring); return 1; }
        cJSON_Delete(row); count++;
    }
    fclose(file);
    assert(count > 0);
    printf("device task shared vectors: %d PASS\n", count);
    file=fopen(argv[2],"rb"); assert(file); count=0;
    while (fgets(line,sizeof(line),file)) {
        cJSON *row=cJSON_Parse(line); assert(row);
        const cJSON *valid=cJSON_GetObjectItemCaseSensitive(row,"valid"), *raw=cJSON_GetObjectItemCaseSensitive(row,"json");
        const cJSON *name=cJSON_GetObjectItemCaseSensitive(row,"name");
        assert(cJSON_IsBool(valid) && cJSON_IsString(raw) && cJSON_IsString(name));
        if (pdsh_task_validate_json(raw->valuestring)!=cJSON_IsTrue(valid)) {
            fprintf(stderr,"task raw JSON vector mismatch: %s\n",name->valuestring); return 1;
        }
        cJSON_Delete(row); count++;
    }
    fclose(file); assert(count>0);
    printf("device task raw JSON vectors: %d PASS\n",count);

    file=fopen(argv[3],"rb"); assert(file); count=0;
    while (fgets(line,sizeof(line),file)) {
        cJSON *row=cJSON_Parse(line); assert(row);
        const cJSON *valid=cJSON_GetObjectItemCaseSensitive(row,"valid"), *hex=cJSON_GetObjectItemCaseSensitive(row,"hex");
        const cJSON *name=cJSON_GetObjectItemCaseSensitive(row,"name");
        assert(cJSON_IsBool(valid) && cJSON_IsString(hex) && cJSON_IsString(name));
        size_t n=strlen(hex->valuestring); assert(n>0 && n%2==0 && n/2<sizeof(line));
        unsigned char raw[sizeof(line)];
        for (size_t i=0;i<n/2;i++) {
            int hi=hex_digit(hex->valuestring[2*i]), lo=hex_digit(hex->valuestring[2*i+1]);
            assert(hi>=0 && lo>=0); raw[i]=(unsigned char)((hi<<4)|lo);
        }
        raw[n/2]=0;
        /* The reference API takes a C string. The NUL vector places that byte
         * inside the JSON value, so truncation must still be rejected. */
        bool got=pdsh_task_validate_json((const char *)raw);
        if (got!=cJSON_IsTrue(valid)) { fprintf(stderr,"task raw bytes vector mismatch: %s\n",name->valuestring); return 1; }
        cJSON_Delete(row); count++;
    }
    fclose(file); assert(count>0);
    printf("device task raw bytes vectors: %d PASS\n",count);
    return 0;
}
