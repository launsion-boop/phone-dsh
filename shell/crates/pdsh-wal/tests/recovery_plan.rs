// SPDX-License-Identifier: MIT
//! The D11 recovery planner (`wal.md` §7.2, §10): one test per rule.
//!
//! Every test is pure: it builds the manifest and the per-segment facts and
//! asserts the plan. No file is read or written, and no fsync happens here.

mod common;

use common::{close, crc32c, manifest, mkdir, name, segment_file, write, BOOT_ID};
use pdsh_wal::{
    next_mseq, scan_segment, Manifest, RecoveryInput, RecoveryPlan, SegmentFacts, SegmentName,
};

fn plan(
    facts: Vec<SegmentFacts>,
    manifest: Option<Manifest>,
    reconcile_marker: bool,
) -> RecoveryPlan {
    RecoveryPlan::plan(RecoveryInput::new(facts, manifest, reconcile_marker))
}

fn corrupt(plan: &RecoveryPlan) -> bool {
    plan.fail.as_ref().map(|error| error.is_corrupt()).unwrap_or(false)
}

#[test]
fn missing_manifest_with_a_full_history_is_rebuilt_from_the_empty_tree() {
    let segment = name(1, 0);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 5))).with_epoch_close(5)];
    let plan = plan(facts, None, false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.replay_segments, vec![segment]);
    assert!(plan.full_reconcile, "§7.2 rebuilds into staging");
    assert!(plan.rebuild_manifest);
    assert!(plan.drop_missing.is_empty());
    assert!(plan.adopt.is_empty());
    assert!(plan.stale.is_empty());
    assert_eq!(plan.effective_tail, 5);
    assert_eq!(plan.next_mseq, 6);
    assert_eq!(plan.next_epoch, 2);
}

#[test]
fn missing_manifest_with_a_truncated_history_fails() {
    let facts = vec![SegmentFacts::verified(name(1, 0), 2, Some((2, 5)))];
    let plan = plan(facts, None, false);
    assert!(corrupt(&plan), "the earliest segment must start at mseq 1");
    assert!(plan.replay_segments.is_empty(), "nothing is touched on failure");
    assert!(!plan.rebuild_manifest);
    assert!(!plan.full_reconcile);
}

#[test]
fn no_manifest_and_no_wal_is_a_new_workspace() {
    let plan = plan(Vec::new(), None, false);
    assert!(plan.is_ok());
    assert!(plan.replay_segments.is_empty());
    assert!(plan.rebuild_manifest, "manifest at 0");
    assert!(!plan.full_reconcile);
    assert_eq!(plan.effective_tail, 0);
    assert_eq!(plan.next_mseq, 1);
    assert_eq!(plan.next_epoch, 1);
}

#[test]
fn a_listed_segment_missing_below_the_watermark_is_dropped_silently() {
    let first = name(1, 0);
    let second = name(1, 1);
    let manifest = manifest(BOOT_ID, 10, 10, 1, &[(first, 1, 5), (second, 6, 10)]);
    let facts = vec![SegmentFacts::verified(first, 1, Some((1, 5)))];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.drop_missing, vec![second]);
    assert_eq!(plan.replay_segments, vec![first]);
    assert!(plan.rebuild_manifest, "the manifest must forget the entry");
    assert_eq!(plan.effective_tail, 10, "last_mseq survives truncation");
    assert_eq!(plan.next_mseq, 11);
}

#[test]
fn a_listed_segment_missing_above_the_watermark_is_corrupt() {
    let first = name(1, 0);
    let second = name(1, 1);
    let manifest = manifest(BOOT_ID, 10, 8, 1, &[(first, 1, 5), (second, 6, 10)]);
    let facts = vec![SegmentFacts::verified(first, 1, Some((1, 5)))];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "unapplied acknowledged history is gone");
    assert!(plan.replay_segments.is_empty());
}

#[test]
fn an_unlisted_tail_above_the_watermark_is_adopted() {
    let first = name(1, 0);
    let open = name(1, 1);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))).with_epoch_close(5),
        SegmentFacts::verified(open, 6, Some((6, 8))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.adopt, vec![open]);
    assert_eq!(plan.replay_segments, vec![first, open]);
    assert!(plan.rebuild_manifest, "the next manifest write lists the tail");
    assert!(plan.manifest_tail_disagreement);
    assert_eq!(plan.effective_tail, 8);
    assert_eq!(plan.next_mseq, 9);
}

#[test]
fn an_adopted_epoch_may_span_two_unlisted_segments() {
    // P4's real shape: the manifest stops at 518, and an open epoch 8 holds
    // 519..550 and 551..582 in two segments. Both are one adopted tail; the
    // second starts above `watermark + 1` but exactly at `attested_tail + 1`.
    let listed = name(1, 0);
    let open_zero = name(8, 0);
    let open_one = name(8, 1);
    let manifest = manifest(BOOT_ID, 518, 518, 0, &[(listed, 1, 518)]);
    let facts = vec![
        SegmentFacts::verified(listed, 1, Some((1, 518))).with_epoch_close(518),
        SegmentFacts::verified(open_zero, 519, Some((519, 550))),
        SegmentFacts::verified(open_one, 551, Some((551, 582))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.adopt, vec![open_zero, open_one]);
    assert_eq!(plan.replay_segments, vec![listed, open_zero, open_one]);
    assert_eq!(plan.effective_tail, 582);
    assert_eq!(plan.next_mseq, 583);
    assert_eq!(plan.next_epoch, 9);
    assert!(plan.rebuild_manifest);
}

#[test]
fn an_adopted_tail_must_continue_the_attested_tail() {
    let first = name(1, 0);
    let open = name(1, 1);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::verified(open, 8, Some((8, 9))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "mseq 6 and 7 are skipped");
}

#[test]
fn an_adopted_tail_may_not_start_above_the_watermark_plus_one() {
    let first = name(1, 0);
    let open = name(1, 1);
    // The manifest tail is 5 but only mseq 1..3 are materialized: a segment
    // starting at 5 would leave 4 unapplied above the copy.
    let manifest = manifest(BOOT_ID, 5, 3, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 3))),
        SegmentFacts::verified(open, 5, Some((5, 6))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "the gap above the watermark cannot be replayed");
}

#[test]
fn the_reconcile_marker_requests_the_staged_reconcile() {
    let first = name(1, 0);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![SegmentFacts::verified(first, 1, Some((1, 5)))];
    let plan = plan(facts, Some(manifest), true);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert!(plan.full_reconcile);
    assert!(plan.clear_reconcile_marker);
    assert_eq!(plan.replay_segments, vec![first]);
}

#[test]
fn a_retained_tail_below_the_materialized_watermark_is_legal() {
    let segment = name(1, 0);
    // Truncation kept the segment but `materialized_upto_mseq` is beyond it.
    let manifest = manifest(BOOT_ID, 120, 120, 3, &[(segment, 1, 110)]);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 110))).with_epoch_close(110)];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.effective_tail, 120);
    assert_eq!(plan.next_mseq, 121, "D17 never reuses an mseq");
    assert_eq!(plan.next_epoch, 4);
    assert!(plan.drop_missing.is_empty());
}

#[test]
fn a_manifest_that_lags_the_records_is_rebuilt() {
    let segment = name(1, 0);
    let manifest = manifest(BOOT_ID, 150, 150, 1, &[(segment, 1, 150)]);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 170)))];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.effective_tail, 170);
    assert_eq!(plan.next_mseq, 171);
    assert!(plan.rebuild_manifest);
    assert!(plan.manifest_tail_disagreement);
    assert!(plan.adopt.is_empty(), "the segment is already listed");
}

#[test]
fn next_mseq_is_max_of_last_mseq_and_the_wal_tail_plus_one() {
    let segment = name(1, 0);
    let manifest = manifest(BOOT_ID, 200, 200, 2, &[(segment, 1, 200)]);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 200))).with_epoch_close(200)];
    let plan = plan(facts, Some(manifest), false);
    assert_eq!(plan.effective_tail, 200);
    assert_eq!(plan.next_mseq, 201);
    assert!(plan.drop_missing.is_empty());
    assert!(!plan.manifest_tail_disagreement);

    assert_eq!(next_mseq(100, 110).unwrap(), 111);
    assert_eq!(next_mseq(200, 150).unwrap(), 201);
    assert!(next_mseq(u64::MAX, 0).is_err());
}

#[test]
fn an_unlisted_header_only_segment_is_stale() {
    let first = name(1, 0);
    let eager = name(1, 1);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::verified(eager, 6, None),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.stale, vec![eager]);
    assert_eq!(plan.replay_segments, vec![first]);
    assert!(plan.adopt.is_empty());
}

#[test]
fn an_unlisted_segment_of_applied_records_is_replayed_then_stale() {
    let kept = name(1, 1);
    let old = name(1, 0);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(kept, 3, 5)]);
    let facts = vec![
        SegmentFacts::verified(old, 1, Some((1, 2))),
        SegmentFacts::verified(kept, 3, Some((3, 5))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.stale, vec![old]);
    assert_eq!(
        plan.replay_segments,
        vec![old, kept],
        "§7.2 replays a stale segment as usual (a no-op)"
    );
    assert_eq!(plan.effective_tail, 5);
}

#[test]
fn a_newer_epoch_close_repairs_the_durable_point() {
    let first = name(1, 0);
    let closed = name(2, 0);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))).with_epoch_close(5),
        SegmentFacts::verified(closed, 6, None).with_epoch_close(5),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.adopt, vec![closed], "retained and re-listed");
    assert!(plan.rebuild_manifest);
    assert_eq!(plan.next_epoch, 3);
}

#[test]
fn a_torn_tail_in_a_non_newest_segment_is_corrupt() {
    let first = name(1, 0);
    let second = name(1, 1);
    let manifest = manifest(BOOT_ID, 8, 8, 1, &[(first, 1, 5), (second, 6, 8)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))).with_torn_tail(60, 10),
        SegmentFacts::verified(second, 6, Some((6, 8))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "a later segment proves the earlier one was complete");
    assert!(plan.truncate.is_empty());
}

#[test]
fn an_unlisted_segment_with_an_unreadable_header_is_corrupt() {
    let first = name(1, 0);
    let broken = name(1, 1);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::unreadable(broken),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan));
}

#[test]
fn a_listed_segment_with_an_unreadable_header_follows_the_missing_rule() {
    let first = name(1, 0);
    let broken = name(1, 1);
    let manifest = manifest(BOOT_ID, 10, 10, 1, &[(first, 1, 5), (broken, 6, 10)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::unreadable(broken),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.drop_missing, vec![broken]);
}

#[test]
fn a_non_tail_crc_failure_is_corrupt_for_listed_and_unlisted_segments() {
    let first = name(1, 0);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let facts = vec![SegmentFacts::verified(first, 1, Some((1, 5))).with_corrupt_tail()];
    assert!(corrupt(&plan(facts, Some(manifest), false)));
}

#[test]
fn a_hole_between_listed_segments_is_corrupt() {
    let first = name(1, 0);
    let third = name(1, 2);
    let manifest = manifest(BOOT_ID, 10, 5, 1, &[(first, 1, 5), (third, 8, 10)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::verified(third, 8, Some((8, 10))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "mseq 6 and 7 are missing above the watermark");
}

#[test]
fn an_overlapping_manifest_range_is_corrupt() {
    let first = name(1, 0);
    let second = name(1, 1);
    let manifest = manifest(BOOT_ID, 10, 10, 1, &[(first, 1, 5), (second, 5, 10)]);
    let facts = vec![
        SegmentFacts::verified(first, 1, Some((1, 5))),
        SegmentFacts::verified(second, 5, Some((5, 10))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "mseq 5 appears twice");
}

#[test]
fn a_listed_segment_with_a_torn_tail_above_the_watermark_is_corrupt() {
    let segment = name(1, 0);
    let manifest = manifest(BOOT_ID, 10, 5, 1, &[(segment, 1, 10)]);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 8))).with_torn_tail(100, 20)];
    let plan = plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "acknowledged mutations above the watermark are lost");
}

#[test]
fn a_listed_segment_with_a_torn_tail_below_the_watermark_is_truncated() {
    let segment = name(1, 0);
    let manifest = manifest(BOOT_ID, 10, 10, 1, &[(segment, 1, 10)]);
    let facts = vec![SegmentFacts::verified(segment, 1, Some((1, 8))).with_torn_tail(100, 20)];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.truncate.len(), 1);
    assert_eq!(plan.truncate[0].keep_len, 100);
    assert_eq!(plan.truncate[0].dropped_bytes, 20);
    assert!(plan.rebuild_manifest, "the recorded range shrank");
    assert_eq!(plan.effective_tail, 10);
    assert_eq!(plan.next_mseq, 11);
}

#[test]
fn duplicate_segment_facts_are_corrupt() {
    let segment = name(1, 0);
    let facts = vec![
        SegmentFacts::verified(segment, 1, Some((1, 5))),
        SegmentFacts::verified(segment, 1, Some((1, 5))),
    ];
    let plan = plan(facts, None, false);
    assert!(corrupt(&plan));
}

#[test]
fn the_planner_reports_the_next_epoch_from_the_directory_and_the_manifest() {
    let first = name(2, 0);
    let manifest = manifest(BOOT_ID, 5, 5, 4, &[(first, 1, 5)]);
    let facts = vec![SegmentFacts::verified(first, 1, Some((1, 5)))];
    let plan = plan(facts, Some(manifest), false);
    assert_eq!(plan.next_epoch, 5, "max(last_durable_epoch 4, segment epoch 2) + 1");
    let without_manifest =
        crate::plan(vec![SegmentFacts::verified(name(7, 3), 1, Some((1, 1)))], None, false);
    assert_eq!(without_manifest.next_epoch, 8);
}

#[test]
fn plan_names_are_stable_across_input_order() {
    let first = name(1, 0);
    let open = name(1, 1);
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(first, 1, 5)]);
    let ordered = plan(
        vec![
            SegmentFacts::verified(first, 1, Some((1, 5))),
            SegmentFacts::verified(open, 6, Some((6, 6))),
        ],
        Some(manifest.clone()),
        false,
    );
    let reversed = plan(
        vec![
            SegmentFacts::verified(open, 6, Some((6, 6))),
            SegmentFacts::verified(first, 1, Some((1, 5))),
        ],
        Some(manifest),
        false,
    );
    assert_eq!(ordered, reversed);
}

/// The plan's segment lists are `SegmentName`s, so ordering is `<epoch,segment>`.
#[test]
fn plan_lists_are_sorted_by_epoch_then_segment() {
    let a = SegmentName::new(1, 0).unwrap();
    let b = SegmentName::new(1, 9).unwrap();
    let c = SegmentName::new(2, 0).unwrap();
    let manifest = manifest(BOOT_ID, 20, 10, 2, &[(b, 6, 10), (a, 1, 5)]);
    let facts = vec![
        SegmentFacts::verified(b, 6, Some((6, 10))),
        SegmentFacts::verified(a, 1, Some((1, 5))),
        SegmentFacts::verified(c, 11, Some((11, 20))),
    ];
    let plan = plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.replay_segments, vec![a, b, c]);
    assert_eq!(plan.adopt, vec![c]);
}

#[test]
fn a_marker_without_a_manifest_or_wal_is_still_cleared() {
    let plan = crate::plan(Vec::new(), None, true);
    assert!(plan.is_ok());
    assert!(plan.rebuild_manifest);
    assert!(plan.full_reconcile, "§7.2: a boot that sees the marker redoes it");
    assert!(plan.clear_reconcile_marker);
}

#[test]
fn a_dropped_segment_epoch_is_never_reused() {
    let present = name(1, 0);
    let dropped = name(3, 0);
    let manifest = manifest(BOOT_ID, 10, 10, 1, &[(present, 1, 5), (dropped, 6, 10)]);
    let facts = vec![SegmentFacts::verified(present, 1, Some((1, 5)))];
    let plan = crate::plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.drop_missing, vec![dropped]);
    assert_eq!(plan.next_epoch, 4, "epoch 3 stays retired");
}

#[test]
fn two_retained_segments_may_not_record_the_same_mutation() {
    let kept = name(1, 1);
    let duplicate = name(1, 0);
    // The stale, unlisted segment repeats the mutations of the listed one: D17
    // forbids reusing an mseq, so this is corruption rather than a no-op replay.
    let manifest = manifest(BOOT_ID, 5, 5, 1, &[(kept, 3, 5)]);
    let facts = vec![
        SegmentFacts::verified(duplicate, 1, Some((1, 5))),
        SegmentFacts::verified(kept, 3, Some((3, 5))),
    ];
    let plan = crate::plan(facts, Some(manifest), false);
    assert!(corrupt(&plan), "mseq 3, 4 and 5 have two records each");
}

/// Bytes → scan → facts → plan, with no hand-written facts: an open epoch after
/// the manifest's checkpoint is adopted and replayed.
#[test]
fn a_scanned_wal_feeds_the_planner_end_to_end() {
    let closed = name(1, 0);
    let open = name(2, 0);
    let first = segment_file(
        1,
        BOOT_ID,
        &[
            write(1, "/dsh/workspace/a.txt", b"a"),
            write(2, "/dsh/workspace/a.txt", b"ab"),
            mkdir(3, "/dsh/workspace/sub"),
            close(1_792_800_000_000, 3),
        ],
    );
    let second = segment_file(
        4,
        BOOT_ID,
        &[
            write(4, "/dsh/workspace/b.txt", b"b"),
            write(5, "/dsh/workspace/b.txt", b"bb"),
        ],
    );
    let facts = vec![
        SegmentFacts::from_scan(closed, &scan_segment(&first, &crc32c)),
        SegmentFacts::from_scan(open, &scan_segment(&second, &crc32c)),
    ];
    let manifest = manifest(BOOT_ID, 3, 3, 1, &[(closed, 1, 3)]);
    let plan = crate::plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.replay_segments, vec![closed, open]);
    assert_eq!(plan.adopt, vec![open]);
    assert!(plan.rebuild_manifest);
    assert_eq!(plan.effective_tail, 5);
    assert_eq!(plan.next_mseq, 6);
    assert_eq!(plan.next_epoch, 3);
}

/// A torn tail turns into a truncation, and the segment below the watermark is
/// kept: bytes → scan → facts → plan.
#[test]
fn a_scanned_torn_tail_becomes_a_truncation() {
    let segment = name(1, 0);
    let mut bytes = segment_file(
        1,
        BOOT_ID,
        &[
            write(1, "/dsh/workspace/a.txt", b"a"),
            write(2, "/dsh/workspace/a.txt", b"ab"),
        ],
    );
    let keep_len = bytes.len();
    bytes.extend_from_slice(&[0xAA; 9]);
    let scan = scan_segment(&bytes, &crc32c);
    assert_eq!(scan.valid_len, keep_len);
    let facts = vec![SegmentFacts::from_scan(segment, &scan)];
    let manifest = manifest(BOOT_ID, 2, 2, 1, &[(segment, 1, 2)]);
    let plan = crate::plan(facts, Some(manifest), false);
    assert!(plan.is_ok(), "{:?}", plan.fail);
    assert_eq!(plan.truncate.len(), 1);
    assert_eq!(plan.truncate[0].keep_len, keep_len);
    assert_eq!(plan.truncate[0].dropped_bytes, 9);
    assert_eq!(plan.next_mseq, 3);
}

/// A non-tail CRC failure survives the whole pipeline as `WAL_CORRUPT`.
#[test]
fn a_scanned_middle_corruption_fails_the_plan() {
    let segment = name(1, 0);
    let records = [
        write(1, "/dsh/workspace/a.txt", b"a"),
        write(2, "/dsh/workspace/a.txt", b"ab"),
        write(3, "/dsh/workspace/a.txt", b"abc"),
    ];
    let mut bytes = segment_file(1, BOOT_ID, &records);
    let first_len = common::record_bytes(&records[0]).len();
    let at = pdsh_wal::HEADER_BYTES + first_len + 8 + 9;
    bytes[at] ^= 0xFF;
    let scan = scan_segment(&bytes, &crc32c);
    assert!(scan.is_corrupt());
    let facts = vec![SegmentFacts::from_scan(segment, &scan)];
    let plan = crate::plan(facts, None, false);
    assert!(corrupt(&plan));
}
