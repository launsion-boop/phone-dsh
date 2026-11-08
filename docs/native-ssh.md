# Native SSH and SCP


These optional capabilities use saved connection aliases, pinned server keys and native credentials.
The Worker never receives passwords, private keys or passphrases. The app's SSH connection allow-list
is separate from the HTTP proxy allow-list. Tool authorization still applies to remote effects.
`ssh --list` lists configured aliases; `ssh [-p port] [-l user] alias command...` executes a
non-interactive command. Port/user overrides must match the saved profile. No forwarding or
interactive PTY is provided. Nonempty initial stdin is explicitly refused; streaming stdin remains
unsupported. Cancellation/deadline closes the SSH channel and connection; a remote process is not
guaranteed to terminate after disconnect, so failed commands must not be automatically retried.

`scp [-r] [-P port] local alias:remote` (or the reverse) uses SFTP over SSH, as modern OpenSSH scp
does. The Worker shell parses operands, resolves the local path, then sends these internal argv:

- Upload: `["scp","--pdsh-v1","upload","file"|"recursive",alias,"default"|port,local,remote]`.
- Download: `["scp","--pdsh-v1","download","file"|"recursive",alias,"default"|port,remote]`.

The upload reads only `/dsh/workspace` or `/dsh/home` after the `requires_mseq` fence. Downloads
emit UTF-8 NDJSON on stdout: `directory {path,name}`, `file {path,name,size}`, `data {data}` (base64),
and `end {path}`; each record uses a `type` field. The root path is empty; descendants are validated
relative paths. The Worker validates the sequence, byte counts and paths, writes a temporary VFS
file and renames only complete files. Incomplete files are removed; previously completed files
remain after a later error. Upload completion emits `uploaded {path,size}`. Native code never
writes downloaded files to the materialized mounts. VFS mutations follow the normal WAL protocol.
Remote uploads can leave partial files on failure, matching ordinary SCP partial-copy behavior.

Transfers are bounded by the configured device byte budget (whole tree), 1,000 entries and depth
32. Wildcards, remote-to-remote transfer, legacy `-O`, preservation options and recursive symlink
traversal are unsupported and must not be advertised. Explicitly named remote sources use the
server's `stat` semantics. SSH stdout/stderr is bounded and truncation produces a nonzero exit.
The canonical request vectors `exec-req-2.json` and `exec-req-3.json` pin this optional surface;
frame types and field schemas remain unchanged.


## Setup and supported keys

In Settings → SSH, add an alias, host, port, username and password or import an
OpenSSH Ed25519/RSA private key. Compare the displayed SHA-256 host fingerprint
with a trusted administrator-provided fingerprint, then confirm it and save.
Credentials live only in the native Keychain. Editing host/port clears trust.
The current Citadel key reader supports unencrypted OpenSSH keys and
AES-128/256-CTR + bcrypt encrypted keys with fewer than 18 rounds (OpenSSH's
default is supported). Other formats/ciphers/KDF settings fail explicitly; do
not weaken an existing key just to import it. A separate compatible key or
password authentication can be used. Prefer Ed25519. RSA authentication uses the
legacy ssh-rsa signature algorithm and will fail on servers which disable it;
the app does not change server policy or enable weaker server algorithms.

Password authentication must also be enabled by the server for that user.
A saved password cannot authenticate to a key-only server; authorize a dedicated
Ed25519 public key there and import its private key into the app instead.

Examples in chat shell tools:

```sh
ssh --list
ssh my-server 'uname -a'
scp report.txt my-server:/tmp/report.txt
scp -r my-server:/tmp/results ./results
```

Connections become available immediately, without an engine restart. Remote
paths are literal SFTP paths: no wildcard/tilde/shell expansion. Native SSH
does not inherit the Worker's cwd or environment. Background iOS suspension
can interrupt a connection; interrupted remote writes are not automatically
retried. Native networking does not need an intermediary HTTP server.

## Android

Android implements the same `ssh` / `scp` accelerators (`android/app/.../com/phonedsh/ssh`)
over the existing exec bridge; the host HELLO advertises `accelerator:ssh` and
`accelerator:scp` only because the tool is registered. Settings → SSH 主机 stores the
profiles in `noBackupFilesDir/ssh/connections.v1.json` (the iOS field names, no secrets)
and each credential as one AES-GCM entry under an `AndroidKeyStore` key (the same
envelope as the model API key). The pinned host key is the only key accepted, the
host-key algorithm is fixed to the pinned key's type, and moving a profile to another
host or port requires a new confirmed fingerprint. A stored password or key is never
loaded back into the editor; a blank field keeps it.

The SSH implementation is JSch 2.28.8 with Bouncy Castle 1.86 (Ed25519 keys/host keys
and X25519 on API 26), both only in `:app`. The pinned Ubuntu Base rootfs carries no
OpenSSH package, so the proot lane cannot provide these accelerators. Differences from
iOS, all on the stricter or bounded side:

- RSA user keys sign with `rsa-sha2-512/256`; the SHA-1 `ssh-rsa` signature is not
  enabled. Keys must be OpenSSH-format Ed25519 or RSA (encrypted keys need their
  passphrase; JSch has no bcrypt-round limit). Keys are pasted; there is no file picker.
- The Android exec bridge returns one completed result per command, so output arrives
  when the command ends and stdout is bounded by `ExecToolResult.MAX_STREAM_BYTES`
  (8 MiB). An SCP download fits the smaller of the device byte budget and what its
  base64 NDJSON records carry in one result (about 6 MiB of file data); beyond it the
  transfer fails with the same limit message.
- `EXEC_CTL cancel` and the deadline close the SSH connection (exit 130 / 124); a
  repeated `idem_key` replays the recorded result instead of re-running the command.

Live tests: `PDSH_SSH_TEST_CONFIG=<fixture>/config.json` runs
`android/app/src/test/.../ssh/SshLiveFixtureTest.kt` against the same fixture as the
Swift tests; without it those cases are skipped.

## Installing an updated build

Rebuild/stage the Worker assets with `examples/probe-app/scripts/copy-bundle-assets.sh`
before building and installing the iOS app. Updating only Swift code leaves the old
Worker in the app bundle: it can apply the local accelerator's three-second deadline
to SSH and send raw SCP operands which the native transfer provider rejects.
The updated Worker must include the SCP VFS adapter and the SSH/SCP remote deadline.

## Verification

Use `scripts/testing/ssh-fixture.py` with a temporary directory (Python
`asyncssh` and `bcrypt`), then set `PDSH_SSH_TEST_CONFIG` to its `config.json`
and run `swift test --filter SSHConnectionTests`. The fixture uses ephemeral
keys, loopback only, a confined SFTP root and fixed test commands. Without the
fixture, network integration tests explicitly skip. Worker tests cover binary
downloads, VFS writes, traversal, cancellation cleanup and the bridge.

References: [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh),
[Citadel](https://github.com/orlandos-nl/Citadel),
[OpenSSH release notes](https://www.openssh.org/releasenotes.html) (9.0 SFTP default).

Citadel is pinned to 0.11.1 because its public connection prehandlers allow the
app to own and close a socket throughout the handshake. In 0.12.1 these
prehandlers are ignored, and its existing-channel entry calls synchronous
pipeline APIs outside the event loop. The stalled-handshake and cancellation
integration tests guard this dependency choice.
