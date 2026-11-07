# CCR: task-journal path and lock identity

```yaml
change: PC-20261107-journal-path-ccr
contracts: [P07, P18]
status: draft
breaking: pending
version_decision: pending
base: 29c491b8
contract_revision: pending
```

`DeviceTaskJournal.records()` checks whether a parent path is a regular,
non-symlink file and then opens it again by path. A concurrent replacement
between those operations can make the checked file differ from the file read.
The journal's lock, parent reads, BLE intent directory, and atomic writes also
resolve paths independently. The existing journal directory is app-private and
the lock is advisory; these facts do not establish stable path identity if a
participant can modify the directory. This audit is not a demonstrated remote
attack and does not authorize deleting or rewriting recovery evidence.

Before implementation the owner must freeze ownership and lifecycle for the
directory and lock, descriptor-relative parent and intent reads/writes,
symlink and non-regular-file handling, file replacement and read races, atomic
rename/fsync behavior, crash recovery and rollback, and compatibility with
existing valid data and supported directory aliases. In-process ownership and
cross-process locking must not accidentally change POSIX lock semantics. No new
record size limit is chosen by this draft. Any bound requires its own evidence
and explicit treatment of existing records, not silent truncation or deletion.

A deterministic test needs real journal operations with controlled replacement
at the enumeration/open and open/read boundaries, regular-file and symlink/FIFO
negatives, repeat inventory, directory alias and cross-process lock cases, and
crash/restart cases for writes. A no-follow final-component read alone can close
only that narrow race; it does not secure the directory path, writes, or a
malicious same-inode writer. Physical power-loss and authentication of historical
BLE receipts require separate evidence. The current raw JSON validation does not
close GAP-24.
