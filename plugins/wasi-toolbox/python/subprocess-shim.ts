// SPDX-License-Identifier: MIT
/**
 * The CPython `subprocess` shim the python tool worker mounts read-only.
 *
 * WASI preview1 has no process model. Stock CPython raises `OSError(ENOTSUP)`
 * from `Popen.__init__`, so every Python task that shells out — a test suite
 * driving its own CLI, `python -m unittest` with a helper process, a script
 * orchestrating snippets — dies with an unstructured traceback before it can
 * do any work. The toolbox's only in-layer mechanism is a nested interpreter
 * instance with piped stdio, so this package installs a module override:
 *
 * - `subprocess.py` is a shadow module in a private read-only preopen. It
 *   loads the *real* `subprocess` from the stdlib zip (the zip stays on
 *   `sys.path` after this directory), patches `Popen` on it and replaces
 *   `sys.modules['subprocess']`, so `import subprocess` inside the guest gets
 *   the standard module with one replacement class. Importing it costs what
 *   the stdlib import always cost; commands that never touch `subprocess` pay
 *   nothing.
 * - `_xl_subprocess.py` is the replacement `Popen`. It frames one request over
 *   the `/__xl__/spawn` control descriptor served by our WASI host
 *   (`src/spawn-bridge.ts`), which runs a fresh interpreter instance on the
 *   *same* tool worker, module, preopen table and `WasiVfs` object as the
 *   parent. That is the same VFS proxy and persistence chain as the shell's
 *   `python3` dispatch (G2-FIX-61); there is no second filesystem path.
 *
 * `run`/`call`/`check_output`/`check_call` from the real module keep working
 * because they build on `Popen`. Programs that are not the interpreter are
 * refused at `Popen` construction with `NotImplementedError` and the list of
 * available programs: a failure the caller can see rather than a fabricated
 * exit 0.
 * @module @phone-dsh/dsh-wasi-toolbox/python/subprocess-shim
 */
import { PDSH_SPAWN_GUEST_PATH } from '../src/spawn-bridge.ts'
import { pythonHttpShimFiles } from './http-shim.ts'

/** Guest directory (and host root of the read-only layer) of the shim files. */
export const PYTHON_SHIM_ROOT = '/python-shims'
/** Filename of the `subprocess` shadow module. */
export const PYTHON_SUBPROCESS_SHIM_FILENAME = 'subprocess.py'
/** Filename of the implementation module the shadow imports. */
export const PYTHON_SUBPROCESS_MODULE_FILENAME = '_xl_subprocess.py'

/**
 * Source of the `subprocess` shadow module.
 *
 * It loads the real stdlib module from the zip instead of importing the name
 * again, patches it, and hands it to `sys.modules` before the import machinery
 * returns (CPython re-reads `sys.modules[name]` after `exec_module`, so the
 * caller receives the patched real module, not this shim).
 */
export const PYTHON_SUBPROCESS_SHIM_SOURCE = `# SPDX-License-Identifier: MIT
"""Load the real subprocess module, install the WASI bridge on it, and stand in
for it in sys.modules.

This file shadows the stdlib module because the read-only shim directory is the
first entry on PYTHONPATH. It never re-implements the module: it reads
subprocess.py from the standard library zip, patches Popen, and lets the import
system return the patched real module.
"""
import importlib.machinery
import importlib.util
import sys


def _stdlib_zip():
    for entry in sys.path:
        if entry and entry.endswith(".zip"):
            return entry
    raise ImportError(
        "the WASI subprocess shim cannot find the standard library zip on sys.path"
    )


_spec = importlib.machinery.PathFinder.find_spec("subprocess", [_stdlib_zip()])
if _spec is None or _spec.loader is None:
    raise ImportError("the WASI subprocess shim cannot load the stdlib subprocess module")

_real = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_real)

import _xl_subprocess

_xl_subprocess.install(_real)
sys.modules["subprocess"] = _real
`

/**
 * Source of `_xl_subprocess.py`: the bridge-backed `Popen` replacement.
 *
 * The framing mirrors `src/spawn-bridge.ts`; `__PDSH_SPAWN_PATH__` is filled in
 * when the layer is mounted so the two ends cannot drift.
 */
export const PYTHON_SUBPROCESS_MODULE_SOURCE = `# SPDX-License-Identifier: MIT
"""Bridge-backed subprocess.Popen for CPython on the DSH WASI toolbox.

WASI preview1 has no fork/exec. The tool worker hosts a private control file at
__PDSH_SPAWN_PATH__; writing one framed request there asks the WASI host to run a
fresh interpreter instance on the same worker, module and VFS, with the caller's
argv, env, cwd and stdin and piped stdout/stderr. This module implements the
Popen surface subprocess.run/call/check_output/check_call build on.

The class runs the child lazily (on communicate/wait/the first stream read)
because a real Popen accepts stdin through communicate(input=...). Execution is
synchronous: WASI cannot hand back a live process, so stdout/stderr are captured
within a shared host-side byte limit and delivered to the caller's targets.
Timeouts are refused before a child starts because this execution path cannot
preempt the synchronous nested interpreter.
"""

import errno
import json
import os
import struct
import sys

_BRIDGE_PATH = "__PDSH_SPAWN_PATH__"
_HEADER_LIMIT = 1024 * 1024
_STREAM_LIMIT = 16 * 1024 * 1024
_READ_CHUNK = 256 * 1024

_fd = None
_table = None
_module = None
_next_pid = 41000


class _BridgeError(OSError):
    """A malformed or truncated frame from the spawn bridge."""


_timeout_warned = False


def _note_unenforced_timeout(timeout, started):
    """Accept timeout= without enforcing it.

    Nested interpreters run synchronously on the same Worker thread, so a child
    cannot be preempted. Refusing the argument broke ordinary scripts that pass
    timeout= defensively; the child now runs to completion, its result is
    returned as usual, and one notice per interpreter says the deadline was not
    applied. The outer command's own timeout still bounds the whole run.
    """
    global _timeout_warned
    if timeout is None or started or _timeout_warned:
        return
    _timeout_warned = True
    try:
        sys.stderr.write(
            "subprocess: timeout= is not enforced in the WASI toolbox; "
            "the nested interpreter runs to completion\\n"
        )
        sys.stderr.flush()
    except (AttributeError, OSError, ValueError):
        pass


def _open_bridge():
    global _fd
    if _fd is None:
        try:
            _fd = os.open(_BRIDGE_PATH, os.O_RDWR)
        except OSError as exc:
            raise NotImplementedError(
                "subprocess is unavailable in this WASI host: the toolbox spawn "
                "bridge " + repr(_BRIDGE_PATH) + " cannot be opened (" + str(exc) + ")"
            ) from exc
    return _fd


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise _BridgeError(errno.EIO, "the WASI spawn bridge refused the request")
        view = view[written:]


def _read_exact(fd, length):
    parts = []
    remaining = length
    while remaining > 0:
        chunk = os.read(fd, min(remaining, _READ_CHUNK))
        if not chunk:
            raise _BridgeError(errno.EIO, "the WASI spawn bridge returned a truncated response")
        parts.append(chunk)
        remaining -= len(chunk)
    return b"".join(parts)


def _call(header, payload=b""):
    fd = _open_bridge()
    header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
    frame = struct.pack("<II", len(header_bytes), len(payload)) + header_bytes + payload
    _write_all(fd, frame)
    (header_length,) = struct.unpack("<I", _read_exact(fd, 4))
    if header_length > _HEADER_LIMIT:
        raise _BridgeError(errno.EIO, "the WASI spawn bridge response header is too large")
    response = json.loads(_read_exact(fd, header_length).decode("utf-8"))
    stdout = _read_exact(fd, int(response.get("stdoutBytes", 0)))
    stderr = _read_exact(fd, int(response.get("stderrBytes", 0)))
    return response, stdout, stderr


def _program_table():
    global _table
    if _table is None:
        response, _stdout, _stderr = _call({"op": "programs"})
        error = response.get("error")
        if error:
            raise NotImplementedError(
                error.get("message") or "the WASI toolbox does not expose a spawn table"
            )
        _table = response
    return _table


def _interpreter_names():
    table = _program_table()
    names = []
    for name in [table.get("interpreter")] + list(table.get("aliases") or []):
        if name and name not in names:
            names.append(name)
    return names


def _resolve_program(program):
    table = _program_table()
    names = _interpreter_names()
    spelling = program or ""
    base = os.path.basename(spelling) if spelling else ""
    # sys.executable is "" in the wasi build: the empty spelling, the value of
    # sys.executable and the aliases the shell table declares all name the
    # running interpreter. Nothing else may be nested.
    if spelling == "" or spelling == sys.executable or spelling in names or base in names:
        return table["interpreter"]
    available = list(table.get("programs") or names)
    raise NotImplementedError(
        "subprocess: " + repr(spelling) + " is not available in the WASI toolbox "
        "(available programs: " + ", ".join(available) + ")"
    )


def install(subprocess_module):
    """Patch one imported stdlib subprocess module in place."""
    global _module
    _module = subprocess_module
    subprocess_module.Popen = Popen


def _text_encoding():
    import locale

    try:
        return locale.getpreferredencoding(False) or "utf-8"
    except Exception:
        return "utf-8"


def _new_pid():
    global _next_pid
    _next_pid += 1
    return _next_pid


class _InputBuffer(object):
    """Stdin pipe buffer: writes are collected until the child starts."""

    def __init__(self, text_mode, encoding, errors):
        self._chunks = []
        self._closed = False
        self._text_mode = text_mode
        self._encoding = encoding or "utf-8"
        self._errors = errors or "strict"

    def write(self, data):
        if self._closed:
            raise ValueError("write to closed file")
        if isinstance(data, str):
            payload = data.encode(self._encoding, self._errors)
        elif isinstance(data, (bytes, bytearray, memoryview)):
            payload = bytes(data)
        else:
            raise TypeError(
                "a bytes-like object is required, not " + repr(type(data).__name__)
            )
        self._chunks.append(payload)
        return len(data)

    def flush(self):
        return None

    def close(self):
        self._closed = True

    def writable(self):
        return True

    def readable(self):
        return False

    def seekable(self):
        return False

    def fileno(self):
        raise OSError(errno.EBADF, "the WASI subprocess stdin is not a file descriptor")

    def _take(self):
        return b"".join(self._chunks)


class _OutputBuffer(object):
    """One captured stdout/stderr pipe, read lazily after the child ran."""

    def __init__(self, popen, name):
        self._popen = popen
        self._name = name
        self._offset = 0
        self._closed = False

    def _data(self):
        self._popen._ensure_run()
        return self._popen._stdout_bytes if self._name == "stdout" else self._popen._stderr_bytes

    def read(self, size=-1):
        data = self._data()
        if size is None or size < 0:
            chunk = data[self._offset:]
            self._offset = len(data)
        else:
            chunk = data[self._offset:self._offset + size]
            self._offset += len(chunk)
        return self._decode(chunk)

    def readline(self, size=-1):
        data = self._data()
        end = data.find(b"\\n", self._offset)
        if end < 0:
            end = len(data)
        else:
            end += 1
        if size is not None and size > 0:
            end = min(end, self._offset + size)
        chunk = data[self._offset:end]
        self._offset = end
        return self._decode(chunk)

    def readlines(self, hint=-1):
        lines = []
        total = 0
        while True:
            line = self.readline()
            if not line:
                return lines
            lines.append(line)
            total += len(line)
            if hint is not None and hint > 0 and total >= hint:
                return lines

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    def close(self):
        self._closed = True

    def flush(self):
        return None

    def readable(self):
        return True

    def writable(self):
        return False

    def seekable(self):
        return False

    def fileno(self):
        raise OSError(errno.EBADF, "the WASI subprocess pipe is not a file descriptor")

    def _decode(self, chunk):
        if self._popen.text_mode:
            return chunk.replace(b"\\r\\n", b"\\n").decode(
                self._popen.encoding, self._popen.errors
            )
        return chunk


def _read_fd(fd):
    parts = []
    total = 0
    while True:
        chunk = os.read(fd, _READ_CHUNK)
        if not chunk:
            break
        parts.append(chunk)
        total += len(chunk)
        if total > _STREAM_LIMIT:
            raise _BridgeError(errno.EFBIG, "subprocess stdin exceeds the WASI bridge limit")
    return b"".join(parts)


def _read_file_object(file):
    reader = getattr(file, "read", None)
    if reader is None:
        raise TypeError("stdin must be None, subprocess.PIPE, a file object or a descriptor")
    data = reader()
    if isinstance(data, str):
        return data.encode(getattr(file, "encoding", None) or "utf-8")
    return bytes(data)


def _write_default(stream, data):
    buffer = getattr(stream, "buffer", None)
    if buffer is not None:
        buffer.write(data)
        buffer.flush()
        return
    stream.write(data.decode("utf-8", "replace"))
    stream.flush()


def _deliver(target, data, default_stream):
    if not data:
        return
    if target is None:
        _write_default(default_stream, data)
        return
    if target is _module.DEVNULL:
        return
    if isinstance(target, int):
        _write_all(target, data)
        return
    writer = getattr(target, "write", None)
    if writer is None:
        raise TypeError("stdout/stderr must be None, subprocess.PIPE, DEVNULL, a file object or a descriptor")
    try:
        writer(data)
    except TypeError:
        writer(data.decode("utf-8", "replace"))
    flush = getattr(target, "flush", None)
    if flush is not None:
        flush()


def _script_index(argv):
    """Index of CPython's script operand, mirroring the toolbox's TS helper."""
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "":
            return index
        if argument == "--":
            following = index + 1
            return following if following < len(argv) else None
        if argument == "-":
            return None
        if not argument.startswith("-"):
            return index
        if argument.startswith("--"):
            if argument == "--check-hash-based-pycs":
                index += 2
                continue
            index += 1
            continue
        flags = argument[1:]
        offset = 0
        consumes_next = False
        exits = False
        while offset < len(flags):
            flag = flags[offset]
            if flag in ("c", "m"):
                return None
            if flag in ("W", "X", "Q"):
                if offset + 1 >= len(flags):
                    consumes_next = True
                offset = len(flags)
                continue
            if flag in ("h", "?", "V"):
                exits = True
                break
            offset += 1
        if exits:
            return None
        index += 2 if consumes_next else 1
    return None


def _rewrite_script_operand(argv, cwd):
    """Make a relative script operand absolute against the child's cwd.

    CPython resolves a script filename during path configuration, before site.py
    imports the cwd shim, so python3 exports/x.py would open /exports/x.py. The
    parent already has the guest cwd and Python's own path rules, so rewrite the
    operand against the *child's* cwd the same way the toolbox does for a shell
    dispatch.
    """
    index = _script_index(argv)
    if index is None:
        return argv
    script = argv[index]
    if script == "" or script.startswith("/"):
        return argv
    rewritten = list(argv)
    rewritten[index] = os.path.normpath(os.path.join(cwd, script))
    return rewritten


class Popen(object):
    """A bridge-backed stand-in for subprocess.Popen on WASI."""

    _child_created = False

    def __init__(self, args, bufsize=-1, executable=None,
                 stdin=None, stdout=None, stderr=None,
                 preexec_fn=None, close_fds=True,
                 shell=False, cwd=None, env=None, universal_newlines=None,
                 startupinfo=None, creationflags=0,
                 restore_signals=True, start_new_session=False, pass_fds=(),
                 *, user=None, group=None, extra_groups=None,
                 encoding=None, errors=None, text=None, umask=-1, pipesize=-1,
                 process_group=None):
        if _module is None:
            raise NotImplementedError("the WASI subprocess shim is not installed")
        if shell:
            raise NotImplementedError(
                "subprocess: shell=True is not available in the WASI toolbox; "
                "run the program directly (bash -c stays in the Worker shell)"
            )
        if preexec_fn is not None:
            raise NotImplementedError("subprocess: preexec_fn is not available in the WASI toolbox")
        if pass_fds:
            raise NotImplementedError("subprocess: pass_fds is not available in the WASI toolbox")
        if startupinfo is not None or creationflags != 0:
            raise ValueError("startupinfo/creationflags are only supported on Windows platforms")
        if start_new_session or process_group not in (None, -1):
            raise NotImplementedError("subprocess: start_new_session/process_group is not available in the WASI toolbox")
        if user is not None or group is not None or extra_groups is not None or umask != -1:
            raise NotImplementedError("subprocess: user/group/umask are not available in the WASI toolbox")
        if stdout is _module.STDOUT:
            raise ValueError("STDOUT can only be used for stderr")
        if text is not None and universal_newlines is not None and bool(text) != bool(universal_newlines):
            raise _module.SubprocessError(
                "Cannot disambiguate when both text and universal_newlines are supplied but different."
            )

        if isinstance(args, (str, bytes, os.PathLike)):
            argv = [os.fsdecode(os.fspath(args))]
            self.args = args
        else:
            argv = [os.fsdecode(os.fspath(item)) for item in args]
            self.args = args
        if not argv:
            raise IndexError("list index out of range")
        self._program = _resolve_program(executable if executable is not None else argv[0])

        self.text_mode = bool(encoding or errors or text or universal_newlines)
        self.encoding = encoding or (_text_encoding() if self.text_mode else None)
        self.errors = errors or ("strict" if self.text_mode else None)

        if cwd is None:
            self._cwd = os.getcwd()
        else:
            self._cwd = os.path.abspath(os.fsdecode(os.fspath(cwd)))
        self._child_argv = _rewrite_script_operand(argv[1:], self._cwd)

        if env is None:
            child_env = dict(os.environ)
        else:
            child_env = {}
            for name, value in env.items():
                child_env[os.fsdecode(name)] = os.fsdecode(value)
        # A nested interpreter still needs its own installation paths to start;
        # they are runtime configuration, not user environment, so they survive
        # an explicit env= just as a real python installation would.
        for name in ("PYTHONHOME", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE", "PYTHONNOUSERSITE",
                     "PDSH_PYTHON_HTTP"):
            if name not in child_env and name in os.environ:
                child_env[name] = os.environ[name]
        child_env["PWD"] = self._cwd
        self._env = child_env

        self._stdin_bytes = b""
        self.stdin = None
        if stdin is _module.PIPE:
            self.stdin = _InputBuffer(self.text_mode, self.encoding, self.errors)
        elif stdin is None or stdin is _module.DEVNULL:
            self._stdin_bytes = b""
        elif isinstance(stdin, int):
            self._stdin_bytes = _read_fd(stdin)
        else:
            self._stdin_bytes = _read_file_object(stdin)

        self._stdout_target = stdout
        self._stderr_target = stderr
        self._stdout_pipe = stdout is _module.PIPE
        self._stderr_pipe = stderr is _module.PIPE
        self._merge_stderr = stderr is _module.STDOUT
        self._stdout_bytes = b""
        self._stderr_bytes = b""
        # Real Popen exposes the pipe objects from construction; ours start the
        # child on the first read, so a direct p.stdout.read() works without
        # communicate().
        self.stdout = _OutputBuffer(self, "stdout") if self._stdout_pipe else None
        self.stderr = _OutputBuffer(self, "stderr") if self._stderr_pipe else None

        self.pid = _new_pid()
        self.returncode = None
        self._started = False
        self._killed_signal = None

    # ------------------------------------------------------------- execution

    def _ensure_run(self):
        if self._started:
            return
        self._started = True
        if self._killed_signal is not None:
            self.returncode = -self._killed_signal
            return
        stdin_bytes = self._stdin_bytes
        if self.stdin is not None:
            stdin_bytes = self.stdin._take()
        header = {
            "op": "exec",
            "argv": list(self._child_argv),
            "env": self._env,
            "cwd": self._cwd,
            "stdinBytes": len(stdin_bytes),
        }
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except (AttributeError, OSError, ValueError):
            pass
        response, stdout, stderr = _call(header, stdin_bytes)
        error = response.get("error")
        if error:
            self._raise_bridge_error(error)
        self.returncode = int(response.get("code", 1))
        if self._merge_stderr:
            stdout = stdout + stderr
            stderr = b""
        self._stdout_bytes = stdout
        self._stderr_bytes = stderr
        if not self._stdout_pipe:
            _deliver(self._stdout_target, self._stdout_bytes, sys.stdout)
        if not self._stderr_pipe and not self._merge_stderr:
            _deliver(self._stderr_target, self._stderr_bytes, sys.stderr)

    def _raise_bridge_error(self, error):
        kind = error.get("kind")
        message = error.get("message") or "the WASI subprocess bridge failed"
        if kind == "cwd":
            raise FileNotFoundError(errno.ENOENT, message, self._cwd)
        if kind == "depth":
            raise OSError(errno.EAGAIN, message)
        if kind == "output-limit":
            raise OSError(errno.EFBIG, message)
        raise _module.SubprocessError(message)

    def _captured(self, name):
        if name == "stdout" and not self._stdout_pipe:
            return None
        if name == "stderr" and not self._stderr_pipe:
            return None
        data = self._stdout_bytes if name == "stdout" else self._stderr_bytes
        if self.text_mode:
            return data.replace(b"\\r\\n", b"\\n").decode(self.encoding, self.errors)
        return data

    # ------------------------------------------------------- Popen interface

    def communicate(self, input=None, timeout=None):
        _note_unenforced_timeout(timeout, self._started)
        if input is not None:
            if self.stdin is None:
                raise ValueError("communicate() input requires stdin=subprocess.PIPE")
            data = input
            if self.text_mode and isinstance(data, str):
                data = data.encode(self.encoding, self.errors)
            elif not self.text_mode and isinstance(data, str):
                raise TypeError("a bytes-like object is required, not 'str'")
            self.stdin.write(data)
            self.stdin.close()
        self._ensure_run()
        return (self._captured("stdout"), self._captured("stderr"))

    def wait(self, timeout=None):
        _note_unenforced_timeout(timeout, self._started)
        self._ensure_run()
        return self.returncode

    def poll(self):
        if not self._started:
            return None
        return self.returncode

    def kill(self):
        self.send_signal(9)

    def terminate(self):
        self.send_signal(15)

    def send_signal(self, sig):
        if self._started:
            return
        self._killed_signal = int(sig)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.wait()

    def __repr__(self):
        return "<Popen: returncode: " + repr(self.returncode) + " args: " + repr(self.args) + ">"
`

/**
 * Ensure the shim directory, the stdlib zip and the cwd shim are on
 * `PYTHONPATH`, in shadowing order: the shim directory must precede the zip so
 * `subprocess` resolves to {@link PYTHON_SUBPROCESS_SHIM_FILENAME}. Entries a
 * caller exported are kept after the runtime's own, so a user `PYTHONPATH`
 * cannot hide the interpreter's installation.
 * @param env - environment the interpreter run will receive.
 * @param options - guest paths of the three runtime entries.
 * @returns a new environment with the runtime `PYTHONPATH`.
 */
export function withPythonShims(
  env: Readonly<Record<string, string>> | undefined,
  options: {
    readonly stdlibZip: string
    readonly cwdShimDir: string
  },
): Record<string, string> {
  const merged: Record<string, string> = { ...(env ?? {}) }
  const entries = [PYTHON_SHIM_ROOT, options.stdlibZip, options.cwdShimDir]
  for (const entry of (merged.PYTHONPATH ?? '').split(':')) {
    if (entry !== '' && !entries.includes(entry)) entries.push(entry)
  }
  merged.PYTHONPATH = entries.join(':')
  return merged
}

/**
 * The read-only layer files this module contributes to one tool worker.
 * @returns absolute host paths and sources of the subprocess and HTTP shims.
 */
export function pythonShimFiles(): readonly { readonly path: string; readonly source: string }[] {
  return [
    { path: `${PYTHON_SHIM_ROOT}/${PYTHON_SUBPROCESS_SHIM_FILENAME}`, source: PYTHON_SUBPROCESS_SHIM_SOURCE },
    {
      path: `${PYTHON_SHIM_ROOT}/${PYTHON_SUBPROCESS_MODULE_FILENAME}`,
      source: PYTHON_SUBPROCESS_MODULE_SOURCE.replaceAll('__PDSH_SPAWN_PATH__', PDSH_SPAWN_GUEST_PATH),
    },
    ...pythonHttpShimFiles(),
  ]
}
