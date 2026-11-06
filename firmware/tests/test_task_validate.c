// SPDX-License-Identifier: MIT
#include "pdsh_task_validate.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    assert(argc == 3);
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
        assert(cJSON_IsBool(valid) && cJSON_IsString(raw));
        assert(pdsh_task_validate_json(raw->valuestring)==cJSON_IsTrue(valid));
        cJSON_Delete(row); count++;
    }
    fclose(file); assert(count>0);
    printf("device task raw JSON vectors: %d PASS\n",count);
    return 0;
}
