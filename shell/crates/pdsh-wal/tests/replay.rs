// SPDX-License-Identifier: MIT
//! D9 idempotent appended replay (`wal.md` §6.2): the three decisions.

use pdsh_wal::{appended_replay, ReplayDecision};

/// The §6.2 example: base 6 bytes, append `A=6` of `world\n`, then `A=12` of
/// `again\n`.
const FIRST: &[u8] = b"world\n";
const SECOND: &[u8] = b"again\n";

#[test]
fn a_file_at_the_offset_applies_the_suffix() {
    assert_eq!(
        appended_replay(6, 6, FIRST, Some(b"")),
        ReplayDecision::Applied
    );
    // An empty suffix at the offset is a no-op append.
    assert_eq!(
        appended_replay(6, 6, b"", Some(b"")),
        ReplayDecision::Applied
    );
}

#[test]
fn a_file_that_already_holds_the_bytes_skips() {
    assert_eq!(
        appended_replay(12, 6, FIRST, Some(FIRST)),
        ReplayDecision::Skip
    );
    // The file may be longer than A + L; only [A, A + L) matters.
    assert_eq!(
        appended_replay(40, 6, FIRST, Some(b"world\nand more bytes")),
        ReplayDecision::Skip
    );
}

#[test]
fn a_missing_or_non_regular_path_is_a_base_mismatch() {
    assert_eq!(
        appended_replay(6, 6, FIRST, None),
        ReplayDecision::Resync
    );
}

#[test]
fn a_file_shorter_than_the_offset_is_a_base_mismatch() {
    assert_eq!(
        appended_replay(5, 6, FIRST, Some(b"")),
        ReplayDecision::Resync
    );
}

#[test]
fn a_partially_appended_suffix_is_a_base_mismatch() {
    // S == 10 lies strictly between A (6) and A + L (12): neither applied nor
    // provably skipped.
    assert_eq!(
        appended_replay(10, 6, FIRST, Some(b"worl")),
        ReplayDecision::Resync
    );
}

#[test]
fn different_bytes_at_the_offset_are_a_base_mismatch() {
    assert_eq!(
        appended_replay(12, 6, FIRST, Some(b"XXXXXX")),
        ReplayDecision::Resync
    );
}

#[test]
fn a_window_shorter_than_the_suffix_is_a_base_mismatch() {
    assert_eq!(
        appended_replay(12, 6, FIRST, Some(b"wor")),
        ReplayDecision::Resync
    );
}

#[test]
fn consecutive_appends_replay_through_a_6_12_and_18_byte_file() {
    // A 6-byte file: the base, so both appends apply in order.
    assert_eq!(
        appended_replay(6, 6, FIRST, Some(b"")),
        ReplayDecision::Applied
    );
    assert_eq!(
        appended_replay(12, 12, SECOND, Some(b"")),
        ReplayDecision::Applied
    );

    // An 18-byte file: both appends are already there.
    assert_eq!(
        appended_replay(18, 6, FIRST, Some(b"world\nagain\n")),
        ReplayDecision::Skip
    );
    assert_eq!(
        appended_replay(18, 12, SECOND, Some(b"again\n")),
        ReplayDecision::Skip
    );

    // A 12-byte file: the first append is present, the second still applies.
    assert_eq!(
        appended_replay(12, 6, FIRST, Some(FIRST)),
        ReplayDecision::Skip
    );
    assert_eq!(
        appended_replay(12, 12, SECOND, Some(b"")),
        ReplayDecision::Applied
    );
}
