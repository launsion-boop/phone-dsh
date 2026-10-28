/* SPDX-License-Identifier: MIT */
/*
 * xzshell.h — C ABI of the phone-dsh phone DSH pdsh-shell read-only
 * accelerators.
 *
 * The native side is a read-only accelerator set: it never writes the
 * workspace and never runs a general shell. Commands are dispatched by name
 * from the registry; only names advertised in the capability JSON may be
 * forwarded by the host.
 *
 * Threading and ownership:
 *   - pdsh_run copies the request synchronously and returns a positive handle
 *     immediately; the command runs on a worker thread. The request budget is
 *     anchored at request_start_nanos when the caller supplies it, so it
 *     includes the synchronous copy/parse.
 *   - The caller must keep `user`, the callbacks object and every request
 *     string alive until pdsh_join returns. The request struct itself may be
 *     freed as soon as pdsh_run returns.
 *   - Output callbacks receive the retained (possibly truncated) stdout and
 *     stderr once, followed by on_exit, all from the worker thread.
 *   - pdsh_join must be called exactly once per handle; after it returns the
 *     handle is invalid. pdsh_cancel may be called before or during the run.
 */
#ifndef XZSHELL_H
#define XZSHELL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Limits of one invocation. A zero timeout_ms means "no deadline". */
typedef struct XzLimits {
    uint64_t timeout_ms;
    size_t max_output_bytes;
    size_t max_files;
    uint64_t max_file_bytes;
} XzLimits;

/* One environment pair. Both strings are NUL-terminated UTF-8. */
typedef struct XzEnvPair {
    const char *key;
    const char *value;
} XzEnvPair;

/* One guest-to-host mount. Guest paths are absolute under /dsh. */
typedef struct XzMount {
    const char *guest;
    const char *host;
} XzMount;

/* One execution request. `argv` includes argv[0], the command name. */
typedef struct XzRequest {
    size_t argc;
    const char *const *argv;
    const char *cwd;
    size_t env_count;
    const XzEnvPair *env;
    size_t mount_count;
    const XzMount *mounts;
    XzLimits limits;
    /*
     * Monotonic request start from pdsh_monotonic_nanos(), or 0 when the
     * caller does not supply one. A non-zero value makes the FFI arm the
     * cancel-token deadline before it parses the request, so C-string
     * construction and request parsing spend the original budget instead of
     * restarting it. Zero keeps the pre-field behaviour: the deadline is
     * armed when pdsh_run starts.
     */
    uint64_t request_start_nanos;
} XzRequest;

/*
 * Output callback. `ptr`/`len` describe retained bytes and are valid only for
 * the duration of the call.
 */
typedef void (*XzOutputCallback)(void *user, const uint8_t *ptr, size_t len);

/* Terminal callback; `code` is the process exit code. */
typedef void (*XzExitCallback)(void *user, int32_t code);

/*
 * Host tool bridge used by the `phone` and `ctx` accelerators.
 *
 * Write at most `out_cap` bytes of the JSON result to `out_buf` and return the
 * number of bytes written. If `out_cap` is too small, write nothing and return
 * the negated required size; the caller retries with a larger buffer. Return
 * -1 (or another negative value that is not a valid retry size) to report
 * that the host could not answer: a failed call, a cancelled call or an
 * expired execution deadline. The FFI reports the cancel token's reason and
 * its 130/124 exit code; the callback must not be used to claim that a
 * cancelled host side effect stopped.
 */
typedef intptr_t (*XzCallToolCallback)(void *user,
                                       const char *name,
                                       const char *args_json,
                                       uint8_t *out_buf,
                                       size_t out_cap);

/* Callbacks of one run. Any member may be NULL. */
typedef struct XzCallbacks {
    XzOutputCallback on_stdout;
    XzOutputCallback on_stderr;
    XzExitCallback on_exit;
    XzCallToolCallback call_tool;
} XzCallbacks;

/* Version string of the linked pdsh-shell. Never NULL; do not free. */
const char *pdsh_version(void);

/*
 * Monotonic clock used by XzRequest.request_start_nanos. The returned value is
 * nanoseconds since the first call in this process; it is not wall-clock time
 * and must only be compared with values from this function.
 */
uint64_t pdsh_monotonic_nanos(void);

/*
 * Capability JSON: {"accelerators":[...],"version":...,"limits":{...}}.
 *
 * Returns the JSON length in bytes. When `buf` is NULL the call only reports
 * the required length. When `cap` is smaller than the length nothing is
 * written and the negated length is returned. Otherwise the JSON is copied to
 * `buf` and a NUL terminator is written when `cap` is larger than the length.
 */
intptr_t pdsh_caps_json(uint8_t *buf, size_t cap);

/*
 * Capability JSON for a caller that can or cannot answer the host tool bridge.
 *
 * A zero `has_tool_bridge` reports only the accelerators that do not need a
 * bridge; the `phone` / `ctx` commands are then not registered and not
 * advertised. A non-zero value is equivalent to pdsh_caps_json. The buffer
 * protocol is the same.
 */
intptr_t pdsh_caps_json_with_bridge(int32_t has_tool_bridge, uint8_t *buf, size_t cap);

/*
 * Start one command. Returns a positive handle on success and -1 when the
 * request or callbacks are invalid (NULL pointer, empty argv, non-UTF-8
 * string, invalid mount, worker thread creation failure).
 */
int32_t pdsh_run(const XzRequest *req, const XzCallbacks *cb, void *user);

/* Request cancellation. Returns 0 for a live handle, -1 when it is unknown. */
int32_t pdsh_cancel(int32_t handle);

/*
 * Wait for completion and return the exit code. Cancelled runs return 130, a
 * timed-out run returns 124, a caught panic returns 70, an unknown command
 * returns 127. Returns -1 for an unknown or already joined handle.
 */
int32_t pdsh_join(int32_t handle);

#ifdef __cplusplus
}
#endif

#endif /* XZSHELL_H */
