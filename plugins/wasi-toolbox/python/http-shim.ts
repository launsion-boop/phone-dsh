// SPDX-License-Identifier: MIT
/**
 * The CPython `urllib`/`http.client` network shim for the WASI toolbox.
 *
 * A wasm32-wasi CPython has no socket and no `ssl` module, so `urllib` reports
 * `ValueError: unknown url type: https` and an `http:` request dies in
 * `socket`. The Worker itself is not allowed to open a socket either: its only
 * egress is the host `POST /v1/http` route. This module mounts `_xl_http.py`
 * in the read-only shim layer; the module speaks the private
 * `/__xl__/http` frame protocol (`src/http-bridge.ts`) and installs a
 * compatible `http.client.HTTPConnection`/`HTTPSConnection` plus
 * `urllib.request` handlers that use it.
 *
 * The bridge only carries the request. The host allow-list decides whether
 * the URL may be reached and the host injects its own credentials; this shim
 * never sees a channel token. `sitecustomize.py` imports it only when the DSH
 * Worker set `PDSH_PYTHON_HTTP=1` (which it does only when a route exists), so
 * a host without the bridge keeps the stock interpreter behaviour.
 * @module @phone-dsh/dsh-wasi-toolbox/python/http-shim
 */
import { PDSH_HTTP_GUEST_PATH } from '../src/http-bridge.ts'

/** File name of the implementation module in the read-only shim directory. */
export const PYTHON_HTTP_SHIM_FILENAME = '_xl_http.py'

/**
 * Source of `_xl_http.py`.
 *
 * Framing mirrors `src/http-bridge.ts`; `__PDSH_HTTP_PATH__` is filled in when
 * the read-only layer is mounted so the two ends cannot drift. The module
 * deliberately implements only the synchronous request/response surface:
 * proxy CONNECT tunnels, client certificates, FTP, chunked/streaming bodies
 * and live streaming downloads fail loud instead of being faked.
 */
export const PYTHON_HTTP_SHIM_SOURCE = String.raw`# SPDX-License-Identifier: MIT
"""Bridge-backed urllib/http.client for CPython on the DSH WASI toolbox.

WASI preview1 has no sockets and this interpreter has no ssl module. The DSH
Worker injects a private control file at __PDSH_HTTP_PATH__; writing one framed
request there asks the host to perform the request on its only egress,
POST /v1/http, where the host allow-list and the host credentials apply.

This module installs a small synchronous HTTPConnection/HTTPSConnection pair
and the urllib.request handlers that use it. It is not a network stack: proxy
tunnels, client certificates, FTP, chunked/streaming uploads and streaming
downloads are refused with NotImplementedError rather than pretended.
"""

import errno
import json
import os
import struct
from urllib.parse import urlsplit

_BRIDGE_PATH = "__PDSH_HTTP_PATH__"
_HEADER_LIMIT = 1024 * 1024
_REQUEST_BODY_LIMIT = 16 * 1024 * 1024
_RESPONSE_BODY_LIMIT = 64 * 1024 * 1024
_READ_CHUNK = 256 * 1024

_fd = None
_installed = False
_METHODS_EXPECTING_BODY = {"PATCH", "POST", "PUT"}

_ERROR_CODES = {
    "protocol": errno.EIO,
    "url": errno.EINVAL,
    "method": errno.EINVAL,
    "limit": errno.EFBIG,
    "network": getattr(errno, "ENETUNREACH", errno.EIO),
    "transport": errno.EIO,
    "internal": errno.EIO,
}


class _BridgeError(OSError):
    """A malformed or truncated frame from the WASI HTTP bridge."""


def _open_bridge():
    global _fd
    if _fd is None:
        try:
            _fd = os.open(_BRIDGE_PATH, os.O_RDWR)
        except OSError as exc:
            raise OSError(
                errno.ENOSYS,
                "Python network is unavailable in this WASI host: the toolbox "
                "HTTP bridge " + repr(_BRIDGE_PATH) + " cannot be opened (" + str(exc) + ")",
            ) from exc
    return _fd


def _write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise _BridgeError(errno.EIO, "the WASI HTTP bridge refused the request")
        view = view[written:]


def _read_exact(fd, length):
    parts = []
    remaining = length
    while remaining > 0:
        chunk = os.read(fd, min(remaining, _READ_CHUNK))
        if not chunk:
            raise _BridgeError(errno.EIO, "the WASI HTTP bridge returned a truncated response")
        parts.append(chunk)
        remaining -= len(chunk)
    return b"".join(parts)


def _header_items(headers):
    """Normalise a mapping or an iterable of pairs to a string-to-string dict."""
    if headers is None:
        return {}
    items = headers.items() if hasattr(headers, "items") else headers
    return {str(name): str(value) for name, value in items}


def _call(method, url, headers=None, body=b""):
    """Perform one request through the host /v1/http route.

    Returns (status, reason, [(name, value), ...], body_bytes). A host failure
    is raised as OSError with the bridge's error class and message; urllib's
    handler turns that into urllib.error.URLError.
    """
    header = {
        "op": "request",
        "method": str(method),
        "url": str(url),
        "headers": _header_items(headers),
    }
    header_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
    if len(header_bytes) > _HEADER_LIMIT:
        raise OSError(
            errno.EFBIG,
            "the HTTP request headers are " + str(len(header_bytes))
            + " bytes; the WASI bridge limit is " + str(_HEADER_LIMIT),
        )
    payload = bytes(body or b"")
    if len(payload) > _REQUEST_BODY_LIMIT:
        raise OSError(
            errno.EFBIG,
            "the HTTP request body is " + str(len(payload))
            + " bytes; the WASI bridge limit is " + str(_REQUEST_BODY_LIMIT),
        )
    frame = struct.pack("<II", len(header_bytes), len(payload)) + header_bytes + payload
    fd = _open_bridge()
    _write_all(fd, frame)
    (header_length,) = struct.unpack("<I", _read_exact(fd, 4))
    if header_length > _HEADER_LIMIT:
        raise _BridgeError(errno.EIO, "the WASI HTTP bridge response header is too large")
    try:
        response = json.loads(_read_exact(fd, header_length).decode("utf-8"))
    except ValueError as exc:
        raise _BridgeError(errno.EIO, "the WASI HTTP bridge response header is not JSON") from exc
    if not isinstance(response, dict):
        raise _BridgeError(errno.EIO, "the WASI HTTP bridge response header is not an object")
    error = response.get("error")
    if error:
        if not isinstance(error, dict):
            error = {}
        kind = str(error.get("kind") or "transport")
        message = str(error.get("message") or "the WASI HTTP bridge failed")
        raise OSError(_ERROR_CODES.get(kind, errno.EIO), message)
    try:
        body_bytes = int(response.get("bodyBytes", 0))
    except (TypeError, ValueError) as exc:
        raise _BridgeError(errno.EIO, "the WASI HTTP bridge response body length is not a number") from exc
    if body_bytes < 0 or body_bytes > _RESPONSE_BODY_LIMIT:
        raise _BridgeError(errno.EFBIG, "the WASI HTTP bridge response body is too large")
    body_data = _read_exact(fd, body_bytes) if body_bytes else b""
    headers_out = []
    for pair in response.get("headers") or []:
        if isinstance(pair, (list, tuple)) and len(pair) == 2:
            headers_out.append((str(pair[0]), str(pair[1])))
    try:
        status = int(response.get("status", 0))
    except (TypeError, ValueError) as exc:
        raise _BridgeError(errno.EIO, "the WASI HTTP bridge response status is not a number") from exc
    reason = str(response.get("reason") or "")
    return status, reason, headers_out, body_data


def _path_and_query(url):
    text = str(url)
    if text == "":
        return "/"
    if not text.startswith("/"):
        return "/" + text
    return text


def _netloc(host, port, default_port):
    text = str(host)
    if ":" in text and not text.startswith("["):
        text = "[" + text + "]"
    number = default_port if port is None else int(port)
    if number == default_port:
        return text
    return text + ":" + str(number)


def _body_bytes(body):
    if body is None:
        return None
    if isinstance(body, str):
        return body.encode("latin-1")
    if isinstance(body, (bytes, bytearray, memoryview)):
        return bytes(body)
    if hasattr(body, "read"):
        raise NotImplementedError(
            "the WASI HTTP bridge reads the whole body before sending; "
            "streaming request bodies are not supported"
        )
    raise TypeError("body must be bytes-like or str, not " + repr(type(body).__name__))


def _headers_message(pairs):
    from email.message import Message

    message = Message()
    for name, value in pairs:
        if name:
            message[name] = value
    return message


class HTTPResponse(object):
    """The synchronous response object returned by HTTPConnection.getresponse()."""

    def __init__(self, method, url, status, reason, header_pairs, body):
        self._method = method
        self.url = url
        self.status = int(status)
        self.code = self.status
        self.reason = reason
        self.msg = reason
        self.headers = _headers_message(header_pairs)
        self._body = body
        self._offset = 0
        self._closed = False
        self.length = len(body)
        self.chunked = False
        self.will_close = True
        self.version = 11

    def info(self):
        return self.headers

    def getheader(self, name, default=None):
        values = self.headers.get_all(name)
        if not values:
            return default
        return ", ".join(values)

    def getheaders(self):
        return list(self.headers.items())

    def geturl(self):
        return self.url

    def read(self, amt=None):
        if self._closed:
            return b""
        if amt is None or amt < 0:
            chunk = self._body[self._offset:]
            self._offset = len(self._body)
        else:
            chunk = self._body[self._offset:self._offset + amt]
            self._offset += len(chunk)
        if self._offset >= len(self._body):
            self._closed = True
        return chunk

    def read1(self, amt=None):
        return self.read(amt)

    def readline(self, limit=-1):
        if self._closed:
            return b""
        end = self._body.find(b"\n", self._offset)
        if end < 0:
            end = len(self._body)
        else:
            end += 1
        if limit is not None and limit > 0:
            end = min(end, self._offset + limit)
        chunk = self._body[self._offset:end]
        self._offset = end
        if self._offset >= len(self._body):
            self._closed = True
        return chunk

    def readinto(self, buffer):
        chunk = self.read(len(buffer))
        buffer[:len(chunk)] = chunk
        return len(chunk)

    def close(self):
        self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False

    def isclosed(self):
        return self._closed

    def flush(self):
        return None

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line


def _response_not_ready(message):
    import http.client as client

    error = getattr(client, "ResponseNotReady", None)
    if isinstance(error, type):
        return error(message)
    return OSError(errno.EINVAL, message)


class HTTPConnection(object):
    """A synchronous HTTPConnection over the host /v1/http route."""

    default_port = 80
    _scheme = "http"
    debuglevel = 0
    _http_vsn = 11
    _http_vsn_str = "HTTP/1.1"

    @staticmethod
    def _get_content_length(body, method):
        if body is None:
            return 0 if method.upper() in _METHODS_EXPECTING_BODY else None
        if hasattr(body, "read"):
            return None
        try:
            return memoryview(body).nbytes
        except TypeError:
            pass
        if isinstance(body, str):
            return len(body)
        return None

    def __init__(self, host, port=None, timeout=None, source_address=None,
                 blocksize=8192, **kwargs):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.source_address = source_address
        self.blocksize = blocksize
        self.debuglevel = 0
        self.sock = None
        self._response = None
        self._method = None
        self._closed = False
        self._tunnel_host = None
        self._http_vsn = 11
        self._http_vsn_str = "HTTP/1.1"
        self._context = kwargs.get("context")
        self._check_hostname = kwargs.get("check_hostname")

    def set_debuglevel(self, level):
        self.debuglevel = int(level)

    def connect(self):
        # There is no socket to connect: the host route is the transport and
        # it is reached only by _call(). Keep the standard method so code that
        # calls connect() explicitly still works.
        self.sock = None

    def set_tunnel(self, host, port=None, headers=None):
        raise NotImplementedError(
            "the WASI HTTP bridge does not support proxy CONNECT tunnels"
        )

    def _host_port(self):
        host = str(self.host)
        port = self.port
        if port is None and host.count(":") == 1 and not host.startswith("["):
            name, _, value = host.partition(":")
            if value.isdigit():
                host = name
                port = int(value)
        return host, port

    def _target_url(self, url):
        text = str(url)
        if text.startswith("http://") or text.startswith("https://"):
            return text
        host, port = self._host_port()
        return self._scheme + "://" + _netloc(host, port, self.default_port) + _path_and_query(text)

    def request(self, method, url, body=None, headers=None, *, encode_chunked=False):
        if self._response is not None:
            raise _response_not_ready("Request-sent")
        text_method = str(method)
        if text_method == "" or any(character.isspace() for character in text_method):
            raise ValueError("invalid HTTP method " + repr(text_method))
        header_items = _header_items(headers)
        lower_names = {name.lower() for name in header_items}
        if encode_chunked or "transfer-encoding" in lower_names:
            raise NotImplementedError(
                "the WASI HTTP bridge does not support chunked or streaming request bodies"
            )
        data = _body_bytes(body)
        target = self._target_url(url)
        if "host" not in lower_names:
            header_items["Host"] = urlsplit(target).netloc
        if data is not None:
            header_items["Content-Length"] = str(len(data))
        status, reason, response_headers, response_body = _call(
            text_method, target, header_items, data or b""
        )
        self._method = text_method
        self._response = HTTPResponse(
            text_method, target, status, reason, response_headers, response_body
        )
        return None

    def getresponse(self):
        response = self._response
        if response is None:
            raise _response_not_ready("Idle")
        self._response = None
        return response

    def close(self):
        response = self._response
        self._response = None
        if response is not None:
            response.close()
        self._closed = True

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


class HTTPSConnection(HTTPConnection):
    """HTTPSConnection whose TLS and credentials are the host's responsibility.

    WASI has no ssl module, so the Python side cannot verify a certificate or
    present a client certificate. The host route performs the TLS connection
    and applies its own allow-list; this class exists so urllib can select an
    https handler and build an https URL.
    """

    default_port = 443
    _scheme = "https"

    def __init__(self, host, port=None, key_file=None, cert_file=None,
                 timeout=None, source_address=None, *, context=None,
                 check_hostname=None, blocksize=8192, **kwargs):
        if key_file is not None or cert_file is not None:
            raise NotImplementedError(
                "the WASI HTTP bridge does not support client certificates"
            )
        HTTPConnection.__init__(
            self, host, port=port, timeout=timeout,
            source_address=source_address, blocksize=blocksize,
            context=context, check_hostname=check_hostname, **kwargs
        )


def install():
    """Patch http.client and urllib.request once; repeated calls are a no-op."""
    global _installed
    if _installed:
        return
    import http.client as client

    client.HTTPConnection = HTTPConnection
    client.HTTPSConnection = HTTPSConnection
    try:
        import urllib.request as request
    except ImportError:
        _installed = True
        return

    base = request.AbstractHTTPHandler

    class _HTTPHandler(base):
        def __init__(self, debuglevel=0):
            base.__init__(self, debuglevel)

        def http_open(self, req):
            return self.do_open(HTTPConnection, req)

        http_request = base.do_request_

    class _HTTPSHandler(base):
        def __init__(self, debuglevel=0, context=None, check_hostname=None):
            base.__init__(self, debuglevel)
            self._context = context
            self._check_hostname = check_hostname

        def https_open(self, req):
            return self.do_open(HTTPSConnection, req)

        https_request = base.do_request_

    request.HTTPHandler = _HTTPHandler
    request.HTTPSHandler = _HTTPSHandler
    # A previously built opener holds the stock handlers (whose HTTPSHandler
    # raised ValueError for missing ssl). Force build_opener to pick these.
    request._opener = None
    _installed = True
`

/**
 * The read-only layer files this module contributes to one tool worker.
 * @returns absolute host path and source of the HTTP shim module.
 */
export function pythonHttpShimFiles(): readonly { readonly path: string; readonly source: string }[] {
  return [{
    path: `/python-shims/${PYTHON_HTTP_SHIM_FILENAME}`,
    source: PYTHON_HTTP_SHIM_SOURCE.replaceAll('__PDSH_HTTP_PATH__', PDSH_HTTP_GUEST_PATH),
  }]
}
