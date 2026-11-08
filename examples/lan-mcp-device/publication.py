# SPDX-License-Identifier: MIT
"""Publish the reference advertisement and verify what DNS-SD actually published.

lan-mcp.md#name-consistency: the SRV target, URL host, SNI and certificate name
are one value H. The OS publisher may choose the SRV target itself, so the
published record is resolved again and compared; any mismatch, rename or
timeout withdraws the advertisement instead of advertising inconsistent values.
"""
import queue
import re
import ssl
import subprocess
import threading
import time

from discovery import PROFILE, SERVICE, canonical_hostname, publication_check

_REACHED = re.compile(r" can be reached at (\S+):(\d+) \(interface ")
_REGISTERED = ": Name now registered and active"


class PublicationError(Exception):
    """A diagnostic from lan-mcp.md (never contains credentials)."""

    def __init__(self, code, detail):
        super().__init__(f"{code}: {detail}")
        self.code = code


def certificate_dns_names(cert_path):
    """Return the leaf certificate's subjectAltName dNSNames."""
    decode = getattr(getattr(ssl, "_ssl", None), "_test_decode_cert", None)
    if decode is None:
        raise PublicationError("certificate_name_missing", "cannot decode certificate names on this Python")
    try:
        decoded = decode(str(cert_path))
    except (OSError, ssl.SSLError) as error:
        raise PublicationError("certificate_name_missing", f"cannot read certificate: {error}") from None
    return [value for kind, value in decoded.get("subjectAltName", ()) if kind == "DNS"]


def check_identity(hostname, cert_path):
    """Startup check: H is canonical-valid and the certificate carries it."""
    canonical = canonical_hostname(hostname)
    if canonical is None:
        raise PublicationError("hostname_invalid", "--hostname is not a valid discovery hostname")
    result = publication_check(canonical, certificate_dns_names(cert_path), canonical, 443, 443)
    if result != "consistent":
        raise PublicationError(result, f"certificate does not name {canonical}")
    return canonical


def parse_lookup(lines):
    """Return (targets, ports, txt_lines) from `dns-sd -L` output."""
    targets, ports, txt = [], [], []
    expect_txt = False
    for line in lines:
        match = _REACHED.search(line)
        if match:
            targets.append(match.group(1))
            ports.append(int(match.group(2)))
            expect_txt = True
        elif expect_txt and line.startswith(" "):
            txt.append(line.strip())
            expect_txt = False
    return targets, ports, txt


class _Lines:
    """Drain a child's stdout on a thread so waits stay bounded."""

    def __init__(self, process):
        self.queue = queue.Queue()
        self.seen = []
        threading.Thread(target=self._read, args=(process.stdout,), daemon=True).start()

    def _read(self, stream):
        for line in stream:
            self.queue.put(line.rstrip("\n"))
        self.queue.put(None)

    def until(self, stop, deadline):
        """Accumulate lines until `stop(seen)` holds (True) or the deadline/EOF (False)."""
        while not stop(self.seen):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            try:
                line = self.queue.get(timeout=remaining)
            except queue.Empty:
                return False
            if line is None:
                return stop(self.seen)
            self.seen.append(line)
        return True


def verify_published(name, hostname, port, timeout, settle=1.0):
    """Resolve the published instance and require target H, the port and the profile TXT."""
    deadline = time.monotonic() + timeout
    lookup = subprocess.Popen(["dns-sd", "-L", name, SERVICE, "local."], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True)
    try:
        lines = _Lines(lookup)
        if lines.until(lambda seen: bool(parse_lookup(seen)[0]), deadline):
            # Several interfaces can answer; gather them briefly, then require all to agree.
            lines.until(lambda seen: False, min(deadline, time.monotonic() + settle))
    finally:
        withdraw(lookup)
    targets, ports, txt = parse_lookup(lines.seen)
    if not targets:
        raise PublicationError("publication_unverified", f"no resolution of {name!r} within {timeout}s")
    for target, srv_port in zip(targets, ports):
        result = publication_check(hostname, [hostname], target, srv_port, port)
        if result != "consistent":
            raise PublicationError(result, f"published {target}:{srv_port}, configured {hostname}:{port}")
    if not txt or any(entry != "profile=" + PROFILE for entry in txt):
        raise PublicationError("publication_unverified", "published TXT is not exactly the profile marker")
    return sorted({canonical_hostname(target) for target in targets})


def publish(name, hostname, port, address=None, timeout=10.0):
    """Start the platform publisher, verify it, and return the running process.

    With `address`, `dns-sd -P` publishes SRV target H with that address record;
    otherwise `dns-sd -R` lets the OS choose the target, which must then equal H.
    """
    if address is None:
        command = ["dns-sd", "-R", name, SERVICE, "local.", str(port), "profile=" + PROFILE]
    else:
        command = ["dns-sd", "-P", name, SERVICE, "local.", str(port), hostname, address, "profile=" + PROFILE]
    publisher = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        expected = f"for service {name}.{SERVICE}.local.{_REGISTERED}"
        lines = _Lines(publisher)
        if not lines.until(lambda seen: any("for service " in line and _REGISTERED in line for line in seen), time.monotonic() + timeout):
            raise PublicationError("publication_unverified", f"{name!r} was not registered within {timeout}s")
        if not any(line.endswith(expected) for line in lines.seen):
            raise PublicationError("publication_unverified", f"{name!r} was renamed or not registered as requested")
        verify_published(name, hostname, port, timeout)
        return publisher
    except BaseException:
        withdraw(publisher)
        raise


def withdraw(publisher):
    if publisher.poll() is None:
        publisher.terminate()
        try:
            publisher.wait(timeout=5)
        except subprocess.TimeoutExpired:
            publisher.kill()
            publisher.wait(timeout=5)
    if publisher.stdout is not None:
        publisher.stdout.close()


def monitor(publisher, name, hostname, port, interval, timeout, on_failure, verify=None, stop=None):
    """Re-verify the advertisement for as long as it is published.

    A publisher exit, rename of the system hostname or any other mismatch
    withdraws the advertisement and calls `on_failure(error)` exactly once.
    """
    verify = verify or verify_published
    stop = stop or threading.Event()

    def run():
        while not stop.wait(interval):
            try:
                if publisher.poll() is not None:
                    raise PublicationError("publication_unverified", "the DNS-SD publisher exited")
                verify(name, hostname, port, timeout)
            except PublicationError as error:
                withdraw(publisher)
                on_failure(error)
                return

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return stop, thread
