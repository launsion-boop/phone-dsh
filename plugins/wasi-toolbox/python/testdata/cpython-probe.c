// SPDX-License-Identifier: MIT
/*
 * cpython-probe: a tiny wasi-libc client used by the G2-FIX-23 regression test.
 *
 * CPython on wasm32-wasi resolves paths through wasi-libc: `sitecustomize` (our
 * startup shim) calls `chdir(PWD)`, then `os.getcwd()`, `open()` and
 * `os.listdir()` all run against the preopens registered by the WASI host.
 * This program performs exactly those libc calls, so the test exercises the
 * same cwd/preopen mechanics as CPython without shipping the 40 MB artifacts.
 *
 * Usage:
 *   cpython-probe --cwd             print "cwd=<getcwd()>"
 *   cpython-probe --list [path]     print one entry per line (default: cwd)
 *   cpython-probe <path>            print "cwd=<getcwd()>" then the file bytes
 *
 * PWD is applied with chdir() when it is an absolute path, mirroring the
 * startup shim. A failed libc call prints "error=<errno>" and exits nonzero.
 *
 * Build with the pinned WASI SDK (same release as the CPython build):
 *   clang --target=wasm32-wasi -Os -Wl,--strip-all \
 *     -o cpython-probe.wasm cpython-probe.c
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int print_cwd(void) {
    char cwd[512];
    if (getcwd(cwd, sizeof cwd) == NULL) {
        printf("error=%d\n", errno);
        return 1;
    }
    printf("cwd=%s\n", cwd);
    return 0;
}

static int list_directory(const char *path) {
    DIR *directory = opendir(path);
    if (directory == NULL) {
        printf("error=%d\n", errno);
        return 1;
    }
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        printf("%s\n", entry->d_name);
    }
    if (closedir(directory) != 0) {
        printf("error=%d\n", errno);
        return 1;
    }
    return 0;
}

static int print_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("error=%d\n", errno);
        return 1;
    }
    char buffer[4096];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof buffer)) > 0) {
        if (fwrite(buffer, 1, (size_t)count, stdout) != (size_t)count) {
            printf("error=%d\n", errno);
            close(fd);
            return 1;
        }
    }
    if (count < 0) {
        printf("error=%d\n", errno);
        close(fd);
        return 1;
    }
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    const char *pwd = getenv("PWD");
    if (pwd != NULL && pwd[0] == '/') {
        if (chdir(pwd) != 0) {
            printf("error=%d\n", errno);
            return 2;
        }
    }
    if (argc < 2) return print_cwd();
    if (strcmp(argv[1], "--cwd") == 0) return print_cwd();
    if (strcmp(argv[1], "--list") == 0) {
        if (print_cwd() != 0) return 1;
        return list_directory(argc > 2 ? argv[2] : ".");
    }
    if (print_cwd() != 0) return 1;
    return print_file(argv[1]);
}
