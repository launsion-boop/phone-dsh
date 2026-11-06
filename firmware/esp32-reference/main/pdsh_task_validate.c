// SPDX-License-Identifier: MIT
#include "pdsh_task_validate.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static bool control(uint32_t cp) {
    static const uint32_t ranges[][2] = {
    {0x0, 0x1f},
    {0x7f, 0x9f},
    {0xad, 0xad},
    {0x600, 0x605},
    {0x61c, 0x61c},
    {0x6dd, 0x6dd},
    {0x70f, 0x70f},
    {0x890, 0x891},
    {0x8e2, 0x8e2},
    {0x180e, 0x180e},
    {0x200b, 0x200f},
    {0x202a, 0x202e},
    {0x2060, 0x2064},
    {0x2066, 0x206f},
    {0xfeff, 0xfeff},
    {0xfff9, 0xfffb},
    {0x110bd, 0x110bd},
    {0x110cd, 0x110cd},
    {0x13430, 0x1343f},
    {0x1bca0, 0x1bca3},
    {0x1d173, 0x1d17a},
    {0xe0001, 0xe0001},
    {0xe0020, 0xe007f}    };
    for (size_t i = 0; i < sizeof(ranges) / sizeof(ranges[0]); i++)
        if (cp >= ranges[i][0] && cp <= ranges[i][1]) return true;
    return false;
}
static bool utf8_text(const char *text, size_t max, bool whitespace) {
    if (!text) return false;
    size_t len = strlen(text);
    if (!len || len > max) return false;
    const unsigned char *p = (const unsigned char *)text;
    while (*p) {
        uint32_t cp; size_t width;
        if (*p < 0x80) { cp = *p; width = 1; }
        else if (*p >= 0xc2 && *p <= 0xdf) { cp = *p & 0x1f; width = 2; }
        else if (*p >= 0xe0 && *p <= 0xef) { cp = *p & 0x0f; width = 3; }
        else if (*p >= 0xf0 && *p <= 0xf4) { cp = *p & 7; width = 4; }
        else return false;
        for (size_t i = 1; i < width; i++) {
            if (!p[i] || (p[i] & 0xc0) != 0x80) return false;
            cp = (cp << 6) | (p[i] & 0x3f);
        }
        if ((width == 2 && cp < 0x80) || (width == 3 && cp < 0x800) ||
            (width == 4 && cp < 0x10000) || cp > 0x10ffff ||
            (cp >= 0xd800 && cp <= 0xdfff)) return false;
        if (control(cp) && !(whitespace && (cp == 9 || cp == 10 || cp == 13))) return false;
        p += width;
    }
    return true;
}
static const char *str(const cJSON *obj, const char *key) {
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(obj, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool id_ok(const char *s) {
    if (!s) return false;
    size_t n = strlen(s);
    if (!n || n > 64) return false;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        bool alnum = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!alnum && (i == 0 || !(c == '.' || c == '_' || c == ':' || c == '-'))) return false;
    }
    return true;
}
static bool timestamp(const char *s, uint64_t *value) {
    if (!s) return false;
    size_t n = strlen(s);
    if (n < 20 || n > 24 || s[4] != '-' || s[7] != '-' || s[10] != 'T' ||
        s[13] != ':' || s[16] != ':' || s[n-1] != 'Z') return false;
    int y=0, m=0, d=0, h=0, min=0, sec=0, millis=0;
    const int digit_pos[] = {0,1,2,3,5,6,8,9,11,12,14,15,17,18};
    for (size_t i=0; i<sizeof(digit_pos)/sizeof(digit_pos[0]); i++)
        if (s[digit_pos[i]] < '0' || s[digit_pos[i]] > '9') return false;
    y=(s[0]-'0')*1000+(s[1]-'0')*100+(s[2]-'0')*10+s[3]-'0';
    m=(s[5]-'0')*10+s[6]-'0'; d=(s[8]-'0')*10+s[9]-'0';
    h=(s[11]-'0')*10+s[12]-'0'; min=(s[14]-'0')*10+s[15]-'0'; sec=(s[17]-'0')*10+s[18]-'0';
    if (n > 20) {
        if (s[19] != '.' || n < 22) return false;
        for (size_t i=20; i<n-1; i++) { if (s[i]<'0' || s[i]>'9') return false; millis=millis*10+s[i]-'0'; }
        for (size_t i=n-21; i<3; i++) millis*=10;
    }
    static const int days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
    if (y < 1 || m < 1 || m > 12 || h > 23 || min > 59 || sec > 59) return false;
    int leap = y%4==0 && (y%100!=0 || y%400==0);
    if (d < 1 || d > days[m-1] + (m==2 && leap)) return false;
    *value = ((((((uint64_t)y*13+(unsigned)m)*32+(unsigned)d)*24+(unsigned)h)*60+(unsigned)min)*60+(unsigned)sec)*1000+(unsigned)millis;
    return true;
}
bool pdsh_task_validate(const cJSON *task) {
    if (!cJSON_IsObject(task) || !id_ok(str(task,"id")) || !id_ok(str(task,"idempotency_key")) ||
        !utf8_text(str(task,"requester"),128,false)) return false;
    uint64_t created, deadline;
    if (!timestamp(str(task,"created_at"), &created)) return false;
    const cJSON *end = cJSON_GetObjectItemCaseSensitive(task,"deadline");
    if (end && (!cJSON_IsString(end) || !timestamp(end->valuestring,&deadline) || deadline<=created)) return false;
    const cJSON *body = cJSON_GetObjectItemCaseSensitive(task,"body");
    const char *type = str(body,"type");
    return cJSON_IsObject(body) && type && !strcmp(type,"goal") && utf8_text(str(body,"text"),768,true);
}
bool pdsh_task_validate_json(const char *json) {
    if (!json) return false;
    // Reject an actual JSON NUL escape, but allow the printable literal "\\u0000".
    bool inside=false;
    for (const char *p=json; *p; p++) {
        if (*p=='"') { inside=!inside; continue; }
        if (inside && *p=='\\' && p[1]) {
            if (p[1]=='u' && !strncmp(p+2,"0000",4)) return false;
            p++;
        }
    }
    const char *end = NULL;
    cJSON *task = cJSON_ParseWithOpts(json, &end, true);
    bool ok = task && end && pdsh_task_validate(task);
    cJSON_Delete(task);
    return ok;
}
