// SPDX-License-Identifier: MIT
//! The D11 recovery planner (`wal.md` §7.2, §10).
//!
//! This module decides, and nothing else. Its input is the manifest (or its
//! absence), the `reconcile.inprogress` marker and the facts of every
//! `wal/*.xlwal` present in the directory — names, header `first_mseq`, mutation
//! range, epoch-close presence, tear verdict. Its output is the plan: which
//! segments the replay pass must read, which files to truncate, which manifest
//! entries to drop, which segments to adopt or unlink, whether the manifest must
//! be rewritten, whether the staged full-tree reconcile is required, and
//! `fail: Some(WAL_CORRUPT)` when recovery must close admission.
//!
//! The rules implemented here are the pure half of D11 and §7.2:
//!
//! * **The `wal/` directory is scanned, not the manifest** — the manifest
//!   `segments[]` list serves truncation only. Unlisted segments are replayed.
//! * **Listed and missing** — dropped silently only when every recorded mutation
//!   is at or below `materialized_upto_mseq`; otherwise `WAL_CORRUPT`.
//! * **Unlisted with a mutation above the watermark** — an adopted tail. Its
//!   first segment must continue the attested tail (`max(last_mseq, highest
//!   listed mutation, materialized_upto_mseq)`), and every later segment of the
//!   same epoch must continue the running attested tail; only the first is
//!   bounded by the watermark + 1. The union then replays idempotently and never
//!   leaves a hole above the watermark.
//! * **Unlisted and nothing above the watermark** — stale: replayed (a no-op)
//!   and **retained**, then verified against the materialized copy and re-listed
//!   in the next manifest write. Unlinking it here is how the G2-A09 class of
//!   silent data loss happened; `wal.md` §7.2 was corrected to require retention
//!   (D16), and this crate only classifies, never unlinks.
//! * **Missing manifest with a WAL** — rebuilt from the empty tree only when the
//!   earliest segment has `first_mseq == 1`; otherwise `Failed`, because a
//!   truncation must have happened and an incomplete root cannot be rebuilt.
//! * **No manifest and no WAL** — a new workspace (`next_mseq = 1`). The
//!   materialized copy is invisible here: the per-OS layer must refuse this plan
//!   when the copy still holds applied files.
//! * **The retained tail above the watermark is strictly contiguous** — a hole
//!   or a duplicated mseq is `WAL_CORRUPT` (D8/D17).
//! * `next_mseq = max(last_mseq, WAL tail) + 1` (D17) and `next_epoch =
//!   max(last_durable_epoch, highest known segment epoch) + 1` (§1), where
//!   "known" includes the epochs the manifest still lists so a retired epoch
//!   number is never reused.
//!
//! Deliberately **not** decided here, because each needs the file system:
//! fsync order (D18), the epoch close, the atomic manifest replace, the staging
//! exchange of the full-tree reconcile, segment unlinks, and the
//! materialized-copy invariant of §7.2 (including the scoped two-file repair).
//! `full_reconcile` and `stale` are the hand-off points for those.
//!
//! `full_reconcile` is set by the `reconcile.inprogress` marker and by a
//! missing-manifest rebuild from the empty tree. §7.2 also lists "the manifest
//! and the WAL tail disagree" as a reconcile trigger, but that sentence is
//! ambiguous: every crash before a manifest write leaves the WAL tail ahead of
//! the checkpoint, and §10 step 3 then replays that tail incrementally. The
//! planner reports the condition separately as
//! [`RecoveryPlan::manifest_tail_disagreement`] and leaves the staged/exchange
//! decision to the layer that can see the materialized copy.

use crate::error::{WalError, WalResult};
use crate::manifest::{next_mseq, Manifest};
use crate::segment::{SegmentName, MAX_EPOCH};
use crate::tear::{SegmentScan, Truncation};

/// What the scanner learned about one segment file present in `wal/`.
///
/// The facts describe the **verified prefix**: [`SegmentFacts::last_mutation_mseq`]
/// and [`SegmentFacts::first_mutation_mseq`] count the records the scan kept, so a
/// torn tail is already excluded and only reported in
/// [`SegmentFacts::torn_tail`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SegmentFacts {
    /// The segment file name.
    pub name: SegmentName,
    /// The header parsed and its CRC verified.
    pub header_ok: bool,
    /// The scan found a failure that is not at the tail (D19 `Corrupt`).
    pub corrupt: bool,
    /// The header's `first_mseq`; 0 when the header is unreadable.
    pub first_mseq: u64,
    /// The lowest mutation mseq in the verified prefix.
    pub first_mutation_mseq: Option<u64>,
    /// The highest mutation mseq in the verified prefix; 0 when none.
    pub last_mutation_mseq: u64,
    /// The epoch-close record's `durable_upto`, when the segment holds one.
    pub epoch_close: Option<u64>,
    /// The torn tail the scan found, with the length to keep.
    pub torn_tail: Option<Truncation>,
}

impl SegmentFacts {
    /// Facts of a present segment from its scan.
    pub fn from_scan(name: SegmentName, scan: &SegmentScan) -> SegmentFacts {
        SegmentFacts {
            name,
            header_ok: scan.header_ok(),
            corrupt: scan.is_corrupt(),
            first_mseq: scan.header.map(|header| header.first_mseq).unwrap_or(0),
            first_mutation_mseq: scan.first_mutation_mseq(),
            last_mutation_mseq: scan.last_mutation_mseq(),
            epoch_close: scan.epoch_close(),
            torn_tail: scan.truncation(name),
        }
    }

    /// A present, header-verified segment with the given mutation range
    /// (`None` for a header-only segment) and no torn tail.
    pub fn verified(
        name: SegmentName,
        first_mseq: u64,
        mutation_range: Option<(u64, u64)>,
    ) -> SegmentFacts {
        SegmentFacts {
            name,
            header_ok: true,
            corrupt: false,
            first_mseq,
            first_mutation_mseq: mutation_range.map(|(first, _)| first),
            last_mutation_mseq: mutation_range.map(|(_, last)| last).unwrap_or(0),
            epoch_close: None,
            torn_tail: None,
        }
    }

    /// A present segment whose header is missing or does not verify.
    pub fn unreadable(name: SegmentName) -> SegmentFacts {
        SegmentFacts {
            name,
            header_ok: false,
            corrupt: false,
            first_mseq: 0,
            first_mutation_mseq: None,
            last_mutation_mseq: 0,
            epoch_close: None,
            torn_tail: None,
        }
    }

    /// The same facts with an epoch-close record carrying `durable_upto`.
    pub fn with_epoch_close(mut self, durable_upto: u64) -> SegmentFacts {
        self.epoch_close = Some(durable_upto);
        self
    }

    /// The same facts with a torn tail.
    pub fn with_torn_tail(mut self, keep_len: usize, dropped_bytes: usize) -> SegmentFacts {
        self.torn_tail = Some(Truncation {
            name: self.name,
            keep_len,
            dropped_bytes,
        });
        self
    }

    /// The same facts with a non-tail failure.
    pub fn with_corrupt_tail(mut self) -> SegmentFacts {
        self.corrupt = true;
        self
    }

    /// `true` when the verified prefix holds at least one record (a mutation or
    /// an epoch close).
    pub fn has_records(&self) -> bool {
        self.first_mutation_mseq.is_some() || self.epoch_close.is_some()
    }
}

/// The pure input of [`RecoveryPlan::plan`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryInput {
    /// Every `wal/*.xlwal` present in the directory, in any order.
    pub wal_dir: Vec<SegmentFacts>,
    /// The manifest, or `None` when it is missing, unreadable or schema-invalid
    /// (the missing-manifest rule of §7.2).
    pub manifest: Option<Manifest>,
    /// `reconcile.inprogress` exists.
    pub reconcile_marker: bool,
}

impl RecoveryInput {
    /// An input.
    pub fn new(
        wal_dir: Vec<SegmentFacts>,
        manifest: Option<Manifest>,
        reconcile_marker: bool,
    ) -> RecoveryInput {
        RecoveryInput {
            wal_dir,
            manifest,
            reconcile_marker,
        }
    }
}

/// The D11 recovery plan. Everything is a list or a flag: the caller performs
/// the I/O, in the order `wal.md` fixes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryPlan {
    /// Every retained segment the replay pass must read, in `<epoch,segment>`
    /// order. Mutations at or below `materialized_upto_mseq` are skipped by the
    /// replay itself; a stale segment is included because §7.2 replays it as
    /// usual (a no-op) and because the copy invariant may need its records.
    pub replay_segments: Vec<SegmentName>,
    /// Torn tails to truncate and log (D19), newest segment only.
    pub truncate: Vec<Truncation>,
    /// Manifest entries to drop: the listed segment file is gone (or its header
    /// is unreadable) and every recorded mutation is at or below the watermark.
    pub drop_missing: Vec<SegmentName>,
    /// Unlisted segments to add to `segments[]` at the next manifest write: an
    /// adopted tail or a newer epoch close that repairs the durable point.
    pub adopt: Vec<SegmentName>,
    /// Unlisted segments that hold nothing above the watermark and no newer
    /// epoch close. **Retain them** (verify against the materialized copy, then
    /// re-list in the next manifest write); do not unlink. `wal.md` §7.2 was
    /// corrected for the G2-A09 class of silent data loss, and this vector is a
    /// classification, not an instruction to delete.
    pub stale: Vec<SegmentName>,
    /// `manifest.json` must be written during recovery.
    pub rebuild_manifest: bool,
    /// The staged full-tree reconcile of §7.2 is required (the marker exists, or
    /// a missing manifest is being rebuilt from the empty tree).
    pub full_reconcile: bool,
    /// `reconcile.inprogress` must be gone once the plan completes.
    pub clear_reconcile_marker: bool,
    /// The manifest and the WAL tail disagree (adopted tail, lagging segment
    /// range, or `last_mseq` below the WAL tail). §7.2 lists this alongside the
    /// marker as a reconcile trigger; see the module docs for why this planner
    /// leaves the staged/exchange decision to the layer that can see the copy.
    pub manifest_tail_disagreement: bool,
    /// The effective tail, `max(last_mseq, highest retained mutation mseq)`;
    /// it may legitimately be **below** `materialized_upto_mseq` (§7.2).
    pub effective_tail: u64,
    /// `max(last_mseq, WAL tail) + 1` (D17).
    pub next_mseq: u64,
    /// The epoch of the next segment 0 (§1).
    pub next_epoch: u32,
    /// `Some(WAL_CORRUPT)` (or the first format failure) when recovery must
    /// fail loud. Every other field is unset then.
    pub fail: Option<WalError>,
}

impl RecoveryPlan {
    /// Plans one recovery. See the module documentation for the rules.
    pub fn plan(input: RecoveryInput) -> RecoveryPlan {
        let mut facts = input.wal_dir;
        facts.sort_by_key(|fact| fact.name);
        for pair in facts.windows(2) {
            if pair[0].name == pair[1].name {
                return RecoveryPlan::failed(WalError::corrupt(format!(
                    "segment {} appears twice in the wal directory",
                    pair[0].name.file()
                )));
            }
        }
        match input.manifest {
            None => plan_without_manifest(facts, input.reconcile_marker),
            Some(manifest) => {
                if let Err(error) = manifest.validate() {
                    return RecoveryPlan::failed(error);
                }
                plan_with_manifest(facts, &manifest, input.reconcile_marker)
            }
        }
    }

    /// `true` when the plan does not fail.
    pub fn is_ok(&self) -> bool {
        self.fail.is_none()
    }

    /// A plan that fails loud.
    pub fn failed(error: WalError) -> RecoveryPlan {
        RecoveryPlan {
            fail: Some(error),
            ..RecoveryPlan::empty()
        }
    }

    fn empty() -> RecoveryPlan {
        RecoveryPlan {
            replay_segments: Vec::new(),
            truncate: Vec::new(),
            drop_missing: Vec::new(),
            adopt: Vec::new(),
            stale: Vec::new(),
            rebuild_manifest: false,
            full_reconcile: false,
            clear_reconcile_marker: false,
            manifest_tail_disagreement: false,
            effective_tail: 0,
            next_mseq: 1,
            next_epoch: 1,
            fail: None,
        }
    }
}

/// §7.2 missing-manifest rule.
fn plan_without_manifest(facts: Vec<SegmentFacts>, marker: bool) -> RecoveryPlan {
    let mut plan = RecoveryPlan::empty();
    plan.clear_reconcile_marker = marker;
    if facts.is_empty() {
        // "With no manifest or WAL, the workspace is new (manifest at 0)."
        plan.rebuild_manifest = true;
        plan.full_reconcile = marker;
        return plan;
    }
    let earliest = &facts[0];
    if !earliest.header_ok {
        return RecoveryPlan::failed(WalError::corrupt(
            "manifest.json is missing and the earliest segment has no readable header",
        ));
    }
    if earliest.first_mseq != 1 {
        return RecoveryPlan::failed(WalError::corrupt(format!(
            "manifest.json is missing and the earliest segment starts at mseq {} instead of 1; \
             a truncation must have happened and the copy cannot be rebuilt from the WAL",
            earliest.first_mseq
        )));
    }
    for fact in &facts {
        if !fact.header_ok {
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "manifest.json is missing and segment {} has no readable header",
                fact.name.file()
            )));
        }
    }
    let truncate = match tear_list(&facts) {
        Ok(truncate) => truncate,
        Err(error) => return RecoveryPlan::failed(error),
    };
    if let Err(error) = check_no_record_corruption(&facts) {
        return RecoveryPlan::failed(error);
    }
    let mut expected = 1u64;
    let mut tail = 0u64;
    for fact in &facts {
        if fact.last_mutation_mseq == 0 {
            continue;
        }
        let Some(first) = fact.first_mutation_mseq else {
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "segment {} has a mutation above mseq 0 but none in its verified prefix",
                fact.name.file()
            )));
        };
        if first != expected {
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "the WAL jumps from mseq {} to {first}; a rebuild from the empty tree has a hole",
                expected - 1
            )));
        }
        match fact.last_mutation_mseq.checked_add(1) {
            Some(next) => expected = next,
            None => {
                return RecoveryPlan::failed(WalError::MseqExhausted);
            }
        }
        tail = fact.last_mutation_mseq;
    }
    let next_mseq = match next_mseq(0, tail) {
        Ok(next) => next,
        Err(error) => return RecoveryPlan::failed(error),
    };
    let next_epoch = match next_epoch_of(&facts, 0) {
        Ok(epoch) => epoch,
        Err(error) => return RecoveryPlan::failed(error),
    };
    plan.replay_segments = facts.iter().map(|fact| fact.name).collect();
    plan.truncate = truncate;
    plan.full_reconcile = true;
    plan.rebuild_manifest = true;
    plan.clear_reconcile_marker = true;
    plan.manifest_tail_disagreement = true;
    plan.effective_tail = tail;
    plan.next_mseq = next_mseq;
    plan.next_epoch = next_epoch;
    plan
}

/// The D11 classification with a manifest.
fn plan_with_manifest(
    facts: Vec<SegmentFacts>,
    manifest: &Manifest,
    marker: bool,
) -> RecoveryPlan {
    let watermark = manifest.materialized_upto_mseq;
    let truncate = match tear_list(&facts) {
        Ok(truncate) => truncate,
        Err(error) => return RecoveryPlan::failed(error),
    };
    if let Err(error) = check_no_record_corruption(&facts) {
        return RecoveryPlan::failed(error);
    }
    let newest = facts.last().map(|fact| fact.name);
    let mut plan = RecoveryPlan::empty();
    plan.truncate = truncate;
    let mut retained: Vec<SegmentName> = Vec::new();
    let mut attested_tail = manifest.last_mseq.max(watermark);
    for segment in &manifest.segments {
        attested_tail = attested_tail.max(segment.last_mseq);
    }

    // Listed segments: used as recorded, or dropped under the missing-segment
    // rule of §7.2/§10 step 1.
    for listed in manifest.segments_sorted() {
        let name = match listed.name() {
            Ok(name) => name,
            Err(error) => return RecoveryPlan::failed(error),
        };
        let Some(fact) = facts.iter().find(|fact| fact.name == name) else {
            if listed.last_mseq <= watermark {
                plan.drop_missing.push(name);
                plan.rebuild_manifest = true;
            } else {
                return RecoveryPlan::failed(WalError::corrupt(format!(
                    "manifest lists segment {} whose mutations reach mseq {} above the materialized \
                     watermark {watermark}",
                    listed.file, listed.last_mseq
                )));
            }
            continue;
        };
        if !fact.header_ok {
            // §10 step 1: an unreadable listed segment follows the
            // missing-segment rule using its recorded mseq range.
            if listed.last_mseq <= watermark {
                plan.drop_missing.push(name);
                plan.rebuild_manifest = true;
                continue;
            }
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "manifest lists segment {} whose header is unreadable and whose mutations reach \
                 mseq {} above the materialized watermark {watermark}",
                listed.file, listed.last_mseq
            )));
        }
        if fact.first_mseq != listed.first_mseq {
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "manifest and WAL disagree on first_mseq of {}: manifest {}, header {}",
                listed.file, listed.first_mseq, fact.first_mseq
            )));
        }
        if fact.last_mutation_mseq < listed.last_mseq {
            let is_newest = Some(name) == newest;
            let torn = fact.torn_tail.is_some();
            if !(is_newest && torn && listed.last_mseq <= watermark) {
                return RecoveryPlan::failed(WalError::corrupt(format!(
                    "manifest records mutations up to {} for {} but the file holds only {}",
                    listed.last_mseq, listed.file, fact.last_mutation_mseq
                )));
            }
            plan.rebuild_manifest = true;
        } else if fact.last_mutation_mseq > listed.last_mseq {
            // The manifest lags the records (a crash before the next rewrite).
            plan.rebuild_manifest = true;
            plan.manifest_tail_disagreement = true;
        }
        retained.push(name);
        attested_tail = attested_tail.max(fact.last_mutation_mseq);
    }

    // Unlisted segments: the directory is the view, the manifest list is not.
    let mut referenced: Vec<SegmentName> = Vec::new();
    for listed in &manifest.segments {
        if let Ok(name) = listed.name() {
            referenced.push(name);
        }
    }
    for fact in &facts {
        if referenced.contains(&fact.name) {
            continue;
        }
        if !fact.header_ok {
            return RecoveryPlan::failed(WalError::corrupt(format!(
                "unlisted WAL segment {} has no readable header",
                fact.name.file()
            )));
        }
        if fact.last_mutation_mseq > watermark {
            let Some(first) = fact.first_mutation_mseq else {
                return RecoveryPlan::failed(WalError::corrupt(format!(
                    "segment {} has a mutation above the watermark but none in its verified prefix",
                    fact.name.file()
                )));
            };
            if first > attested_tail.saturating_add(1) {
                return RecoveryPlan::failed(WalError::corrupt(format!(
                    "adopted WAL tail {} starts at mseq {first} after the attested tail \
                     {attested_tail}",
                    fact.name.file()
                )));
            }
            // The gap above the watermark is covered by the previously adopted
            // segments (or by listed segments above it): `attested_tail` is the
            // end of that covered prefix and is advanced after every adoption.
            // Requiring every adopted segment to start at `watermark + 1` would
            // reject a legal multi-segment adopted epoch — the P4 shape of two
            // unlisted segments `<epoch>.0` (519..550) and `<epoch>.1` (551..582)
            // above a manifest that stops at 518. `check_retained_tail` still
            // proves the union is strictly contiguous and covers `last_mseq`.
            plan.adopt.push(fact.name);
            retained.push(fact.name);
            plan.rebuild_manifest = true;
            plan.manifest_tail_disagreement = true;
            attested_tail = attested_tail.max(fact.last_mutation_mseq);
        } else if fact.epoch_close.is_some() && fact.name.epoch > manifest.last_durable_epoch {
            // A newer epoch close repairs the durable point: retain and re-list.
            plan.adopt.push(fact.name);
            retained.push(fact.name);
            plan.rebuild_manifest = true;
        } else if fact.has_records() {
            // All applied: replayed as a no-op, then stale.
            plan.stale.push(fact.name);
            retained.push(fact.name);
        } else {
            // Header-only: never content, never the only copy of a write.
            plan.stale.push(fact.name);
        }
    }

    // D17: one mutation mseq has exactly one record, so the retained mutation
    // ranges are pairwise disjoint even below the watermark.
    if let Err(error) = check_no_duplicate_ranges(&facts, &retained) {
        return RecoveryPlan::failed(error);
    }
    // §7.2/D8: the retained tail above the watermark is strictly contiguous and
    // covers the acknowledged tail.
    if let Err(error) = check_retained_tail(&facts, &retained, watermark, manifest.last_mseq) {
        return RecoveryPlan::failed(error);
    }
    let wal_tail = union_tail(&facts, &retained, watermark);
    let effective_tail = manifest.last_mseq.max(wal_tail);
    let next_mseq = match next_mseq(manifest.last_mseq, wal_tail) {
        Ok(next) => next,
        Err(error) => return RecoveryPlan::failed(error),
    };
    let listed_epoch = manifest
        .segments
        .iter()
        .map(|segment| segment.epoch)
        .max()
        .unwrap_or(0);
    let next_epoch = match next_epoch_of(&facts, manifest.last_durable_epoch.max(listed_epoch)) {
        Ok(epoch) => epoch,
        Err(error) => return RecoveryPlan::failed(error),
    };

    plan.replay_segments = retained;
    plan.replay_segments.sort();
    plan.drop_missing.sort();
    plan.adopt.sort();
    plan.stale.sort();
    plan.rebuild_manifest |= manifest.last_mseq != effective_tail;
    if manifest.last_mseq != effective_tail {
        plan.manifest_tail_disagreement = true;
    }
    plan.full_reconcile = marker;
    plan.clear_reconcile_marker = marker;
    plan.effective_tail = effective_tail;
    plan.next_mseq = next_mseq;
    plan.next_epoch = next_epoch;
    plan
}

/// Only the newest segment of the directory may be torn: a later segment proves
/// the earlier one was written completely, so a tear there is corruption.
fn tear_list(facts: &[SegmentFacts]) -> WalResult<Vec<Truncation>> {
    let newest = facts.last().map(|fact| fact.name);
    let mut truncate = Vec::new();
    for fact in facts {
        let Some(truncation) = &fact.torn_tail else {
            continue;
        };
        if Some(fact.name) != newest {
            return Err(WalError::corrupt(format!(
                "segment {} has a torn tail but is not the newest segment",
                fact.name.file()
            )));
        }
        truncate.push(truncation.clone());
    }
    Ok(truncate)
}

/// §10 step 2: a failure that is not at the tail is `WAL_CORRUPT`, listed or not.
fn check_no_record_corruption(facts: &[SegmentFacts]) -> WalResult<()> {
    for fact in facts {
        if fact.corrupt {
            return Err(WalError::corrupt(format!(
                "segment {} has a length or CRC failure that is not at its tail",
                fact.name.file()
            )));
        }
    }
    Ok(())
}

/// D17: a mutation mseq appears in at most one retained segment, so no two
/// retained mutation ranges may overlap (a truncation may leave gaps, not
/// duplicates).
fn check_no_duplicate_ranges(facts: &[SegmentFacts], retained: &[SegmentName]) -> WalResult<()> {
    let mut ranges: Vec<(u64, u64)> = Vec::new();
    for name in retained {
        let Some(fact) = facts.iter().find(|fact| fact.name == *name) else {
            continue;
        };
        if let Some(first) = fact.first_mutation_mseq {
            ranges.push((first, fact.last_mutation_mseq));
        }
    }
    ranges.sort_unstable();
    let mut covered = 0u64;
    for (first, last) in ranges {
        if first <= covered {
            return Err(WalError::corrupt(format!(
                "mseq {first} appears in more than one retained WAL segment"
            )));
        }
        covered = last;
    }
    Ok(())
}

/// The highest mutation mseq in the retained segments, clamped at `watermark`.
fn union_tail(facts: &[SegmentFacts], retained: &[SegmentName], watermark: u64) -> u64 {
    retained
        .iter()
        .filter_map(|name| facts.iter().find(|fact| fact.name == *name))
        .map(|fact| fact.last_mutation_mseq)
        .fold(watermark, u64::max)
}

/// The retained replay window above the watermark must be strictly contiguous
/// and cover the acknowledged tail (`wal.md` §7.2, D8/D17).
fn check_retained_tail(
    facts: &[SegmentFacts],
    retained: &[SegmentName],
    watermark: u64,
    last_mseq: u64,
) -> WalResult<()> {
    let mut ranges: Vec<(u64, u64)> = Vec::new();
    for name in retained {
        let Some(fact) = facts.iter().find(|fact| fact.name == *name) else {
            continue;
        };
        if fact.last_mutation_mseq <= watermark {
            continue;
        }
        let first = fact
            .first_mutation_mseq
            .unwrap_or_else(|| watermark.saturating_add(1))
            .max(watermark.saturating_add(1));
        ranges.push((first, fact.last_mutation_mseq));
    }
    ranges.sort_unstable();
    let mut covered = watermark;
    for (first, last) in ranges {
        if first > covered.saturating_add(1) {
            return Err(WalError::corrupt(format!(
                "the retained WAL jumps from mseq {covered} to {first}"
            )));
        }
        if first <= covered {
            return Err(WalError::corrupt(format!(
                "mseq {first} appears in more than one retained WAL segment"
            )));
        }
        covered = last;
    }
    let acknowledged = last_mseq.max(watermark);
    if covered < acknowledged {
        return Err(WalError::corrupt(format!(
            "the retained WAL ends at mseq {covered}, below the acknowledged tail {acknowledged}"
        )));
    }
    Ok(())
}

/// `max(last_durable_epoch, highest epoch of any existing segment) + 1` (§1).
/// `floor` also carries the highest epoch the manifest still lists, so an epoch
/// number freed by a dropped segment is not reused.
fn next_epoch_of(facts: &[SegmentFacts], floor: u32) -> WalResult<u32> {
    let highest = facts.iter().map(|fact| fact.name.epoch).fold(floor, u32::max);
    let next = highest.checked_add(1).ok_or(WalError::EpochExhausted)?;
    if next > MAX_EPOCH {
        return Err(WalError::EpochExhausted);
    }
    Ok(next)
}
