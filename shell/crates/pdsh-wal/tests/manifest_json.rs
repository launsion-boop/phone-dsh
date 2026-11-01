// SPDX-License-Identifier: MIT
//! `manifest.json` (`wal.md` §7) and the minimal JSON reader.

mod common;

use common::{manifest, name, BOOT_ID};
use pdsh_wal::{next_mseq, Manifest, ManifestSegment, WalError};

/// Canonical JSON of the D5 form, as the host writes it (`sortedKeys`, no
/// whitespace, `/` unescaped).
const CANONICAL: &str = concat!(
    r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"#,
    r#""last_durable_epoch":3,"last_mseq":46,"materialized_upto_mseq":46,"#,
    r#""segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","#,
    r#""first_mseq":1,"last_mseq":46}]}"#
);

#[test]
fn the_canonical_manifest_reads_and_re_emits_byte_for_byte() {
    let manifest = Manifest::parse(CANONICAL).expect("manifest parses");
    assert_eq!(manifest.format, 1);
    assert_eq!(manifest.boot_id_hex(), "00112233445566778899aabbccddeeff");
    assert_eq!(manifest.materialized_upto_mseq, 46);
    assert_eq!(manifest.last_mseq, 46);
    assert_eq!(manifest.last_durable_epoch, 3);
    assert_eq!(manifest.segments.len(), 1);
    assert_eq!(
        manifest.segments[0],
        ManifestSegment::new(name(1, 0), 1, 46)
    );
    assert_eq!(manifest.to_json(), CANONICAL);
    assert_eq!(manifest.next_mseq(60).expect("next"), 61);
}

#[test]
fn members_are_sorted_and_segments_are_ordered() {
    let built = manifest(
        BOOT_ID,
        20,
        20,
        2,
        &[(name(2, 0), 11, 20), (name(1, 0), 1, 10)],
    );
    let text = built.to_json();
    let boot = text.find("\"boot_id\"").expect("boot_id");
    let format = text.find("\"format\"").expect("format");
    let durable = text.find("\"last_durable_epoch\"").expect("last_durable_epoch");
    let last = text.find("\"last_mseq\"").expect("last_mseq");
    let watermark = text.find("\"materialized_upto_mseq\"").expect("watermark");
    let segments = text.find("\"segments\"").expect("segments");
    assert!(boot < format && format < durable && durable < last);
    assert!(last < watermark && watermark < segments);
    let first = text.find("wal/00000001.000000.xlwal").expect("epoch 1");
    let second = text.find("wal/00000002.000000.xlwal").expect("epoch 2");
    assert!(first < second, "segments[] is in <epoch,segment> order");
    let parsed = Manifest::parse(&text).expect("round trip");
    assert_eq!(parsed.to_json(), text);
    let sorted: Vec<ManifestSegment> = built.segments_sorted().into_iter().cloned().collect();
    assert_eq!(parsed.segments, sorted);
}

#[test]
fn unknown_members_are_ignored() {
    let text = CANONICAL.replace("\"format\":1", "\"format\":1,\"future\":\"x\"");
    let manifest = Manifest::parse(&text).expect("unknown members are ignored");
    assert_eq!(manifest.last_mseq, 46);
}

#[test]
fn an_empty_manifest_is_the_new_workspace() {
    let text = concat!(
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"#,
        r#""last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#
    );
    let manifest = Manifest::parse(text).expect("manifest");
    assert!(manifest.segments.is_empty());
    assert_eq!(manifest.next_mseq(0).expect("next"), 1);
    assert_eq!(manifest.to_json(), text);
}

#[test]
fn shape_errors_are_manifest_invalid_so_the_missing_rule_applies() {
    let cases = [
        "[]",
        "",
        r#"{"format":1}"#,
        r#"{"boot_id":"00112233445566778899AABBCCDDEEFF","format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"0011","format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":1.5,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":{}}"#,
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"\u0030\u0030","format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":-1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]} x"#,
    ];
    for text in cases {
        match Manifest::parse(text) {
            Err(WalError::ManifestInvalid(_)) => {}
            other => panic!("{text:?} must be ManifestInvalid, got {other:?}"),
        }
    }
}

#[test]
fn impossible_contents_are_wal_corrupt() {
    let cases = [
        // materialized watermark above last_mseq
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":5,"materialized_upto_mseq":6,"segments":[]}"#,
        // format is not 1
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":2,"last_durable_epoch":0,"last_mseq":0,"materialized_upto_mseq":0,"segments":[]}"#,
        // a segment names a mutation above last_mseq
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":5,"materialized_upto_mseq":5,"segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":1,"last_mseq":6}]}"#,
        // overlapping ranges
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":10,"materialized_upto_mseq":10,"segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":1,"last_mseq":5},{"epoch":1,"file":"wal/00000001.000001.xlwal","first_mseq":5,"last_mseq":10}]}"#,
        // the file name says epoch 2, the member says 1
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":5,"materialized_upto_mseq":5,"segments":[{"epoch":1,"file":"wal/00000002.000000.xlwal","first_mseq":1,"last_mseq":5}]}"#,
        // first_mseq 0
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":5,"materialized_upto_mseq":5,"segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":0,"last_mseq":5}]}"#,
        // an inverted range with a mutation
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":10,"materialized_upto_mseq":10,"segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":9,"last_mseq":5}]}"#,
        // the same segment listed twice
        r#"{"boot_id":"00112233445566778899aabbccddeeff","format":1,"last_durable_epoch":0,"last_mseq":5,"materialized_upto_mseq":5,"segments":[{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":1,"last_mseq":5},{"epoch":1,"file":"wal/00000001.000000.xlwal","first_mseq":1,"last_mseq":5}]}"#,
    ];
    for text in cases {
        match Manifest::parse(text) {
            Err(error) if error.is_corrupt() => {}
            other => panic!("{text:?} must be WAL_CORRUPT, got {other:?}"),
        }
    }
}

#[test]
fn a_header_only_segment_listing_uses_zero_last_mseq() {
    let built = manifest(BOOT_ID, 5, 5, 1, &[(name(1, 1), 6, 0)]);
    let text = built.to_json();
    let parsed = Manifest::parse(&text).expect("an idle-close segment has last_mseq 0");
    assert_eq!(parsed.segments[0].last_mseq, 0);
    assert_eq!(parsed.segments[0].first_mseq, 6);
    // Round trip: the zero is the "no mutation" form of §7, not an inversion.
    assert_eq!(parsed.to_json(), text);
}

#[test]
fn next_mseq_formula_is_d17() {
    assert_eq!(next_mseq(0, 0).expect("next"), 1);
    assert_eq!(next_mseq(5, 5).expect("next"), 6);
    assert_eq!(next_mseq(5, 9).expect("next"), 10);
    assert_eq!(next_mseq(9, 5).expect("next"), 10);
    assert!(matches!(next_mseq(u64::MAX, 0), Err(WalError::MseqExhausted)));
}

#[test]
fn the_json_reader_is_a_strict_subset() {
    let value = pdsh_wal::json::parse(r#" { "a" : [1, 2, {"b": null}], "c": true } "#)
        .expect("subset parses");
    assert_eq!(value.get("a").and_then(|value| value.as_array()).map(|a| a.len()), Some(3));
    assert_eq!(
        value
            .get("a")
            .and_then(|value| value.as_array())
            .and_then(|array| array[2].get("b")),
        Some(&pdsh_wal::json::Json::Null)
    );
    assert_eq!(value.get("c"), Some(&pdsh_wal::json::Json::Bool(true)));

    let escaped = pdsh_wal::json::parse(r#""a\"b\\c\/d""#).expect("escapes");
    assert_eq!(escaped.as_str(), Some("a\"b\\c/d"));

    for bad in ["", "{", "[1,]", "01", "1e3", "{} {}", r#""\u0030""#, r#"{"a":1,"a":2}"#] {
        assert!(pdsh_wal::json::parse(bad).is_err(), "{bad:?} must not parse");
    }
}
