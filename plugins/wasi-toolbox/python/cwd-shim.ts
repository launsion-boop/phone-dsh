// SPDX-License-Identifier: MIT
/**
 * The cwd startup shim of the CPython package.
 *
 * WASI preview1 has no "current directory" argument and no `chdir` import:
 * a process starts in `/`, and wasi-libc only tracks a cwd after `chdir()`.
 * The toolbox resolves the bash tool's workdir into the `/dsh` guest
 * namespace and exports it as `PWD` (see `WasiToolbox.execute`); this module
 * is mounted read-only next to the stdlib zip and imported by `site.py` on
 * every interpreter start, so `os.getcwd()` and every relative `open()` see
 * the directory the shell ran the command in — not an unpreopened `/`.
 *
 * The module is deliberately tiny and side-effect free when the environment
 * carries no absolute `PWD`: an image whose stdlib zip is used by another
 * host keeps working, and a cwd outside the preopened roots fails the
 * standard `os.chdir` `OSError` path instead of escaping the VFS.
 * @module @phone-dsh/dsh-wasi-toolbox/python/cwd-shim
 */

/** Directory name of the shim below the stdlib guest root. */
export const PYTHON_CWD_SHIM_DIR_NAME = 'python-cwd'
/** File name `site.py` imports at interpreter start. */
export const PYTHON_CWD_SHIM_FILENAME = 'sitecustomize.py'

/**
 * Source of the mounted `sitecustomize.py`.
 *
 * `site.py` imports `sitecustomize` after it has assembled `sys.path`, and
 * before any `-c` code or script runs, so the chdir applies to the user
 * program while the imports that set Python up still resolve at the root.
 */
export const PYTHON_CWD_SHIM_SOURCE = `# SPDX-License-Identifier: MIT
"""Apply the Worker shell's cwd before the user program runs on WASI.

WASI preview1 starts with no usable working directory; wasi-libc only
tracks one after chdir(). The DSH toolbox resolves the bash tool's workdir
into the /dsh guest namespace and exports it as PWD, so the interpreter
chdirs into the same directory the shell command ran in.
"""
import os

_target = os.environ.get("PWD") or ""
if _target.startswith("/"):
    try:
        os.chdir(_target)
    except OSError:
        # The shell may have removed the directory; keep Python on the root
        # rather than failing interpreter startup for a stale PWD.
        pass

# The DSH Worker sets PDSH_PYTHON_HTTP=1 only when it injected loopback
# /v1/http coordinates. Without the flag (or without the mounted shim) the
# interpreter starts exactly as before: a missing optional bridge must never
# make every python3 fail to start.
if os.environ.get("PDSH_PYTHON_HTTP") == "1":
    try:
        import _xl_http

        _xl_http.install()
    except Exception:
        pass
`

/**
 * Guest directory that must be on `PYTHONPATH` for `site.py` to find the shim.
 * It sits beside the stdlib zip, inside the read-only stdlib preopen.
 * @param stdlibGuestPath - guest path of the stdlib zip.
 * @returns absolute guest directory of the shim module.
 */
export function pythonCwdShimGuestDir(stdlibGuestPath: string): string {
  const normalized = stdlibGuestPath.replace(/\/+$/, '')
  const slash = normalized.lastIndexOf('/')
  const root = slash <= 0 ? '/' : normalized.slice(0, slash)
  return `${root === '/' ? '' : root}/${PYTHON_CWD_SHIM_DIR_NAME}`
}

/**
 * Prepend the shim directory to `PYTHONPATH` without dropping the caller's
 * entries (the stdlib zip is one of them).
 * @param env - environment of the interpreter run.
 * @param shimDir - guest directory returned by {@link pythonCwdShimGuestDir}.
 * @returns a new environment whose `PYTHONPATH` starts with the shim.
 */
export function withPythonCwdShim(
  env: Readonly<Record<string, string>> | undefined,
  shimDir: string,
): Record<string, string> {
  const merged: Record<string, string> = { ...(env ?? {}) }
  const entries = (merged.PYTHONPATH ?? '').split(':').filter(entry => entry !== '')
  if (!entries.includes(shimDir)) entries.unshift(shimDir)
  merged.PYTHONPATH = entries.join(':')
  return merged
}
