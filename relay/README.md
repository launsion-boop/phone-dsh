# PCLink v1 public relay (P28, B stage)

This directory is the self-contained PCLink relay plane. It implements
`spec/pclink/v1/README.md` §3 (including the `pclink-v1.4` clarifications in
§3.4/§3.5) and the relay side of the §4.3 pairing rendezvous. It does **not**
implement, inspect or decrypt the end-to-end protocol: `e2e.body` and
`relay.pair.message.payload` are opaque to this process.

- Runtime: Node.js ≥ 20, one dependency (`ws` pinned to exactly `8.21.3`).
- State: memory only. No database, volume, queue, log file or other disk write.
- Deployment: one stateless container, non-root, read-only root filesystem
  friendly, listening on port 8080 behind a TLS-terminating reverse proxy.
- Transport: WebSocket text frames on the `/` path; `GET /healthz` returns 200.
- Contract authority: [`../spec/pclink/v1/README.md`](../spec/pclink/v1/README.md)
  and the change record
  [`../docs/protocol-changes/PC-20261109-pclink-v1.md`](../docs/protocol-changes/PC-20261109-pclink-v1.md)
  §4.1. This is the B-stage implementation against the `pclink-v1.4`
  §3.4/§3.5 clarification; P28 stays `target` until the integrator has the real
  relay/WSS, PC and iPhone runtime evidence described in the change record.

## What it does

- Per-connection `relay.challenge` with a fresh 32-byte nonce and the configured
  public origin.
- `peer.auth` Ed25519 verification over
  `"pclink-v1/relay-auth" || 0x00 || relay || 0x00 || nonce`, machineId
  derivation from the presented public key, role claim validation, 10-second
  authentication deadline, same-machineId replacement (`replaced`/4001) and
  role-conflict rejection (`auth_failed`/4002).
- `relay.ready`, then `e2e` / `e2e.handshake` routing by authenticated
  machineId. The relay overwrites `from`; it never trusts a client-supplied
  `from`.
- PC `relay.allow` lists (the target PC's accepted senders). Non-listed `e2e`
  application frames are dropped silently. `e2e.handshake` bypasses the list
  only for `session.init` / `session.resp` / `session.confirm` /
  `session.reject`, and is separately rate-limited per source and target. A
  phone has no relay allowlist: the relay forwards to it and the phone drops
  unknown senders locally. The allowlist is a spam filter, not an authorization
  boundary; the PC still validates every frame against its local pairing table
  and AEAD state.
- `relay.offline` when the target is not connected; nothing is queued.
- Pairing rendezvous `relay.pair.open/join/joined/message/close`: 300-second
  absolute expiry, one successful join, ten total join attempts, five joins
  per source IP per minute, at most two open slots per PC connection, and
  `peer_offline` close on participant disconnect. The rendezvous is an opaque
  22-character key; it is never decoded, inspected or logged.
- `relay.ping`/`relay.pong` every 20–30 seconds, close after two unanswered
  pings, and a 10-minute phone idle close (`session_expired`/4004). A business
  frame forwarded to or from the phone resets the idle timer. The PC is not
  idle-closed by the relay.
- The §3.5 limits: per-IP connections (IPv6 /64, released only on the real
  socket close), per-machineId-pair bandwidth and burst with single-frame token
  overdraft, 16 MiB authenticated frame cap, 4 KiB pre-auth frame cap before
  JSON parsing, 24 MiB outbound buffer cap per target connection (drop the
  frame and return `rate_limited`, never queue it), per-machineId UTC-day
  bytes with a 100,000-counter cap, unauthenticated timeout, handshake buckets,
  join rate and rendezvous attempts.
- Metadata-only stdout logs: timestamp, event, hashed machineId prefix,
  source-IP HMAC prefix, frame type/length and error code. No body, payload,
  rendezvous, pairing code, nonce, signature or token.

`relay.redirect` is reserved by the contract. The relay never sends it and
rejects it from clients; clients ignore it if another implementation sends it.

## Run locally

```sh
cd relay
npm ci
PCLINK_PUBLIC_ORIGIN=http://127.0.0.1:3220 \
  node relay.mjs --host 127.0.0.1 --port 3220
```

`PCLINK_PUBLIC_ORIGIN` is required. The relay sends exactly that normalized
origin in `relay.challenge.relay` and never guesses it from a `Host` header.
Uppercase origins, paths, queries, userinfo and explicit default ports are
rejected. `http://` is accepted only for `127.0.0.1`/`localhost` loopback tests;
production must be `https://` (clients derive `wss://`).

Health check:

```sh
curl -fsS http://127.0.0.1:3220/healthz
```

CLI options: `--host`, `--port`, `--quiet`, `--help`. The environment is the
normal configuration surface.

## Environment variables

The defaults below are the frozen contract values. A self-hosted deployment may
tune them, but changing a default changes what that deployment promises; the
public relay should keep the contract defaults.

| Variable | Default | Meaning |
| --- | ---: | --- |
| `PCLINK_PUBLIC_ORIGIN` | **required** | Public `https://` origin (or loopback `http://` for tests). Sent in `relay.challenge.relay`. |
| `PCLINK_MAX_CONNECTIONS_PER_IP` | 20 | Active connections per source IP; IPv6 is aggregated by /64. |
| `PCLINK_PAIR_RATE_BYTES_PER_SEC` | 1048576 | Token-bucket rate for bytes forwarded between one unordered machineId pair (1 MiB/s). |
| `PCLINK_PAIR_BURST_BYTES` | 4194304 | Burst size for the same pair bucket (4 MiB). A single larger frame may overdraw a full bucket; the debt refills at the rate. |
| `PCLINK_MAX_FRAME_BYTES` | 16777216 | Maximum authenticated client frame; values above 16 MiB refuse startup. |
| `PCLINK_UNAUTHENTICATED_MAX_FRAME_BYTES` | 4096 | Maximum frame before `relay.ready`, checked before JSON parsing. Must be ≤ `PCLINK_MAX_FRAME_BYTES`. |
| `PCLINK_MAX_BUFFERED_BYTES_PER_CONNECTION` | 25165824 | Per-target outbound-buffer cap (24 MiB). A frame that would exceed it is dropped with `rate_limited`; the target stays and nothing is queued. |
| `PCLINK_DAILY_BYTES_PER_MACHINE` | 2147483648 | UTC-day forwarded bytes per machineId (2 GiB); memory-only and reset by restart. |
| `PCLINK_DAILY_BYTES_MAX_MACHINES` | 100000 | Maximum daily byte counters per day; a new machineId at the cap evicts the oldest counter (best-effort quota). |
| `PCLINK_PAIR_JOINS_PER_IP_PER_MINUTE` | 5 | Pairing joins per source IP (/64 for IPv6). |
| `PCLINK_PAIR_ATTEMPTS_PER_RENDEZVOUS` | 10 | Total join attempts per rendezvous; the next is `rendezvous_exhausted`. |
| `PCLINK_PAIR_RENDEZVOUS_TTL_SECONDS` | 300 | Absolute rendezvous lifetime. |
| `PCLINK_MAX_PAIR_SLOTS_PER_CONNECTION` | 2 | Open pairing slots per relay connection. v1 clients open one. |
| `PCLINK_HANDSHAKE_FRAMES_PER_SOURCE_PER_MINUTE` | 30 | `e2e.handshake` frames per source machineId; burst is `ceil(value/3)` (10). |
| `PCLINK_HANDSHAKE_FRAMES_PER_TARGET_PER_MINUTE` | 300 | `e2e.handshake` frames per target machineId; burst is `ceil(value/3)` (100). |
| `PCLINK_AUTH_TIMEOUT_MS` | 10000 | `relay.challenge` → valid `peer.auth` deadline. |
| `PCLINK_PHONE_IDLE_MS` | 600000 | Phone close after no authenticated business frame. |
| `PCLINK_HEARTBEAT_MIN_MS` | 20000 | Lower bound of the relay ping interval. |
| `PCLINK_HEARTBEAT_MAX_MS` | 30000 | Upper bound of the relay ping interval. |
| `PCLINK_TRUSTED_PROXIES` | empty | Comma-separated proxy IPs/CIDRs. `X-Forwarded-For` is consulted only when the direct peer is in this list. |

`X-Forwarded-For` is ignored unless `PCLINK_TRUSTED_PROXIES` contains the direct
peer address. When it is trusted, the relay walks the header right-to-left and
uses the first untrusted address. Only enable this for your reverse proxy, or a
client can spoof the per-IP buckets.

## Container

```sh
cd relay
PCLINK_PUBLIC_ORIGIN=https://relay.example docker compose up -d --build
```

Set `PCLINK_RELAY_TAG` to override the image tag (default `latest`). The compose
file:

- publishes `8080`;
- sets `read_only: true`, runs as the image's non-root `node` user, drops all
  capabilities and sets `no-new-privileges`;
- has no volumes and no writable paths;
- checks `/healthz` with the container's Node runtime.

The image is `node:22-alpine`; `npm ci --omit=dev` installs only the pinned
`ws`. There is no shell entrypoint and no startup migration.

### Reverse proxy requirements

- Terminate TLS (TLS 1.2+) and forward WebSocket upgrades for the `/` path.
  The frozen contract derives the WSS URL from the public origin with `/`;
  if your edge only exposes `/v1/peer`, rewrite that path to `/` at the proxy.
- `proxy_http_version 1.1`, `Upgrade`/`Connection` forwarding, response
  buffering off.
- WebSocket idle timeout comfortably above 30 s (at least 300 s is sensible;
  the application pings every 20–30 s).
- Allow at least 16 MiB messages.
- Forward the client address in `X-Forwarded-For` and list the proxy in
  `PCLINK_TRUSTED_PROXIES`.
- Route `GET /healthz` to the same container.

The container does not need outbound network access.

## Privacy

- **No content storage.** The relay has no database, no volume, no queue and
  writes no files. `e2e.body` is opaque ciphertext; the relay never parses,
  decrypts or logs it. Pairing `payload` objects are forwarded verbatim and are
  not inspected.
- **Metadata.** The relay necessarily sees the outer headers (`v`, `type`,
  `sid`, `seq`, `from`, `to`, frame sizes), roles, machineIds, the relay↔public-
  key mapping, pairing payload objects (the contract treats their keys, names
  and MACs as relay-visible; the relay does not inspect or log their fields) and
  timing. PCLink v1 does not provide identity hiding.
- **Logs.** Runtime logs go to stdout only. machineIds appear only as short
  SHA-256 prefixes and source IPs only as a prefix of an HMAC-SHA-256 keyed by a
  random salt generated at process start (never persisted, changes on restart);
  frame type/length and error code are logged. Bodies, payloads, rendezvous
  values, pairing codes, nonces, signatures and tokens are not logged. Set your
  platform's log retention to 7 days or less.
- **Restart.** All allowlists, rendezvous, counters and quotas are in memory
  and disappear on restart. A daily quota is best-effort across restarts.
- **No store-and-forward.** A message for an offline peer produces
  `relay.offline` and is not queued.

## Service terms (summary)

This is a free, best-effort public forwarding service provided as-is, with no
SLA, warranty or availability guarantee. There is no content storage, backup or
message replay. The operator may apply the documented rate limits, close
abusive or excessive connections, or suspend the service. Users are
responsible for their own devices, pairing approval, revoking lost devices and
for complying with applicable law. The software is MIT-licensed; self-hosting
is supported and encouraged when the public relay is unsuitable.

This summary is not legal advice; a production deployment should publish its
own jurisdiction-appropriate terms and privacy notice.

## Tests and contract evidence

```sh
cd relay
npm ci
npm test
```

The suite uses Node's built-in `node:test` and covers authentication and
origin binding, replacement/role conflict, routing and the target-PC allowlist,
`relay.offline`, pair rendezvous expiry/single-success/join attempts/slot caps,
per-IP (including IPv6 /64, trusted `X-Forwarded-For` and close-time release),
per-pair bandwidth with single-frame overdraft, daily byte and handshake
buckets, slow-receiver backpressure, the pre-auth frame cap, heartbeats, phone
idle close in both directions, restart re-authentication, parser heap bounds,
static and runtime no-filesystem-write assertions, and metadata-only
(source-IP HMAC) logging.

The tests drive the real relay parser/auth/base32/machineId code with the shared
fixtures:

- `spec/pclink/v1/golden/pclink-v1-vectors.json`: machineId/relay-auth vectors
  plus the shared invalid encoding/origin rows;
- `spec/pclink/v1/golden/schema-samples.json`: every relay-plane valid sample is
  accepted and every invalid sample is rejected. `pairing-message` samples are
  intentionally not treated as relay-plane: the relay must not parse the
  pairing payload.

Run the shared contract checks too (from the repository root):

```sh
node spec/pclink/v1/tools/vectors.mjs --check
python3 spec/pclink/v1/tools/check_samples.py --root .
```

## Limitations

- Single instance; no sharding. `relay.redirect` is reserved but not sent.
- No persistence, so allowlists/rendezvous/quotas are lost on restart and
  clients must re-authenticate. The reconnect test covers this.
- Pairing and E2E cryptography live in the PC plugin and iOS module, not here.
  The relay only proves possession of the identity key and forwards bytes.
- A relay operator can observe metadata and deny service; it cannot read or
  modify an `e2e` body. That trust model is stated in the frozen contract.
