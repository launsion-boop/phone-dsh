# iOS queued delivery readiness — first residency increment

Base: 29a733cb8f8f764e27629b5e126fcf572b042168.
Protocol impact: P09; P06: none — existing SendOutbox schema, rpcId and authoritative reconciliation remain unchanged; P12: none — no SDK module or ABI changes.

This implements the architecture's first existing-outbox delivery slice, not APNs or a new
cold-target admission store. Scope is iOS and already-bound local DSH sessions. Bot-specific
admission, account-scoped external credentials, first-ever session persistence and new native
SQLite admission remain subsequent increments; no remote endpoint is added.

Freeze: ChatDeliveryPreparation decision takes foreground/background execution eligibility,
host presence, parked state, lifecycle/busy state, transport readiness and manual-recovery state.
It returns ready / start / resume / wait / deferred / needsAttention. Background may deliver
only to an already-ready host held by the existing keep-alive path. It never cold-boots or
resumes a parked host. Foreground queued work may start/resume via existing ChatModel methods.
A single recoveryFlushTask owns preparation, with the existing bounded 30s wait and host
boot/resume bounds. No new lifecycle state machine or timer-based idle eviction is introduced.

Admission remains SendOutbox's durable enqueue for an existing session. The entry's sessionId
and rpcId never change during preparation. Errors/timeouts keep the entry and existing
outcomeUnknown/read-back rules; a prepare result is never a delivery/execute receipt.
Foreground return retries queued preparation even when host is absent. First-ever background
send with no session is refused rather than booting or falsely promising durable acceptance.
The 1800s turn watchdog, device grant windows, background boot gate and user recovery remain.

Compatibility: same on-disk records and same downstream actions on old/new versions; only
when preparation is attempted changes. Android is unchanged. No persisted format/version bump.

Acceptance: policy regression matrix (parked host, busy transition, background constraints,
manual recovery), real SendOutbox reopen preserves target/key/state and never retries unknown
outcomes, Swift compilation of changed App source. Device/BLE/APNs and power tests are NOT_RUN
until actually executed; this increment does not claim to finish R0–R5.
