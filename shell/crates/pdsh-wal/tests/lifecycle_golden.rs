// SPDX-License-Identifier: MIT
//! §7.2/§9/§10 lifecycle vectors (`spec/v1/golden/wal/lifecycle`).
//!
//! The Rust end is a classification planner: it does not implement the §9
//! quota/compaction unlink phase. These vectors therefore drive the real
//! `RecoveryPlan` over each fixture and assert the §7.2 half (listed ranges,
//! adopted tails, stale re-listing, replay set) plus the segment bytes. The
//! Swift runner executes the §9 droppable/fast-path half against
//! `RecoveryManager`; the Python checker recomputes the declared expectations.

mod common;

use std::fs;

use common::{crc32c, golden_wal_dir, hex_decode};
use pdsh_wal::json::Json;
use pdsh_wal::{
    scan_segment, Manifest, ManifestSegment, RecoveryInput, RecoveryPlan, SegmentFacts,
};

fn lifecycle_dir() -> std::path::PathBuf {
    golden_wal_dir().join("lifecycle")
}

fn strings(value: &Json, where_: &str) -> Vec<String> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("{where_}: expected an array"))
        .iter()
        .map(|item| {
            item.as_str()
                .unwrap_or_else(|| panic!("{where_}: expected a string"))
                .to_string()
        })
        .collect()
}

fn string(value: &Json, name: &str) -> String {
    value
        .get(name)
        .and_then(Json::as_str)
        .unwrap_or_else(|| panic!("missing string {name}"))
        .to_string()
}

fn uint(value: &Json, name: &str) -> u64 {
    value
        .get(name)
        .and_then(Json::as_u64)
        .unwrap_or_else(|| panic!("missing integer {name}"))
}

fn manifest_from(value: &Json) -> Manifest {
    let boot = hex_decode(&string(value, "boot_id"));
    let boot_id: [u8; 16] = boot.try_into().expect("16-byte boot id");
    let segments = value
        .get("segments")
        .and_then(Json::as_array)
        .expect("manifest segments")
        .iter()
        .map(|entry| {
            let file = string(entry, "file");
            let parsed = pdsh_wal::SegmentName::parse(&file).expect("segment name");
            ManifestSegment::new(
                parsed,
                uint(entry, "first_mseq"),
                uint(entry, "last_mseq"),
            )
        })
        .collect();
    Manifest::new(
        boot_id,
        uint(value, "materialized_upto_mseq"),
        uint(value, "last_mseq"),
        u32::try_from(uint(value, "last_durable_epoch")).expect("epoch fits u32"),
        segments,
    )
}

#[test]
fn every_lifecycle_vector_matches_the_recovery_planner() {
    let dir = lifecycle_dir();
    let mut names: Vec<String> = fs::read_dir(&dir)
        .expect("lifecycle golden directory exists")
        .map(|entry| entry.expect("directory entry").file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".json"))
        .collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "crash-tail-epoch-above-durable.json".to_string(),
            "unclosed-epoch-above-watermark.json".to_string(),
            "unclosed-epoch-below-watermark.json".to_string(),
            "unlisted-adopted-tail.json".to_string(),
            "unlisted-stale-relisted.json".to_string(),
        ],
        "expected exactly the five frozen lifecycle vectors"
    );

    for file_name in names {
        let path = dir.join(&file_name);
        let text = fs::read_to_string(&path).expect("lifecycle vector is readable");
        let vector = pdsh_wal::json::parse(&text).expect("lifecycle vector is JSON");
        let manifest = manifest_from(vector.get("manifest").expect("manifest member"));
        manifest.validate().expect("the golden manifest is valid §7");

        let mut facts = Vec::new();
        let mut present = Vec::new();
        for (index, raw) in vector
            .get("segments")
            .and_then(Json::as_array)
            .expect("segments member")
            .iter()
            .enumerate()
        {
            let where_ = format!("{file_name}: segments[{index}]");
            let file = string(raw, "file");
            let segment_name = pdsh_wal::SegmentName::parse(&file).expect("segment name");
            let bytes = hex_decode(
                raw.get("file_hex")
                    .and_then(Json::as_str)
                    .expect("file_hex member"),
            );
            assert!(!bytes.is_empty(), "{where_}: lifecycle vectors use non-empty segments");
            let scan = scan_segment(&bytes, &crc32c);
            assert!(scan.header_ok(), "{where_}: header parses");
            assert!(!scan.is_corrupt(), "{where_}: records are clean");
            assert!(scan.chain_error.is_none(), "{where_}: record order");
            let fact = SegmentFacts::from_scan(segment_name, &scan);
            assert_eq!(fact.first_mseq, uint(raw, "first_mseq"), "{where_}: first_mseq");
            assert_eq!(
                fact.last_mutation_mseq,
                uint(raw, "last_mseq"),
                "{where_}: last_mseq"
            );
            assert_eq!(
                fact.epoch_close.is_some(),
                raw.get("has_epoch_close")
                    .and_then(|value| match value {
                        Json::Bool(value) => Some(*value),
                        _ => None,
                    })
                    .expect("has_epoch_close boolean"),
                "{where_}: epoch-close presence"
            );
            facts.push(fact);
            present.push(segment_name);
        }

        // The manifest's listed ranges match the real bytes.
        for listed in &manifest.segments {
            let fact = facts
                .iter()
                .find(|fact| fact.name.file() == listed.file)
                .unwrap_or_else(|| panic!("{file_name}: listed segment {} is absent", listed.file));
            assert_eq!(fact.first_mseq, listed.first_mseq, "{file_name}: listed first_mseq");
            assert_eq!(
                fact.last_mutation_mseq, listed.last_mseq,
                "{file_name}: listed last_mseq"
            );
        }

        let plan = RecoveryPlan::plan(RecoveryInput::new(facts, Some(manifest), false));
        assert!(plan.is_ok(), "{file_name}: {plan:?}");
        assert!(plan.drop_missing.is_empty(), "{file_name}: nothing is missing");
        assert!(!plan.full_reconcile, "{file_name}: no reconcile marker");

        let expected = vector.get("expected").expect("expected member");
        let adopted: Vec<String> = strings(expected.get("adopted_tail_segments").expect("adopted"), "adopted");
        let stale: Vec<String> = strings(expected.get("relisted_segments").expect("relisted"), "relisted")
            .into_iter()
            .filter(|file| !adopted.contains(file))
            .collect();
        assert_eq!(
            plan.adopt.iter().map(|name| name.file()).collect::<Vec<_>>(),
            adopted,
            "{file_name}: adopted tail"
        );
        assert_eq!(
            plan.stale.iter().map(|name| name.file()).collect::<Vec<_>>(),
            stale,
            "{file_name}: stale re-listing"
        );

        let mut expected_replay: Vec<String> = present.iter().map(|name| name.file()).collect();
        expected_replay.sort();
        assert_eq!(
            plan.replay_segments
                .iter()
                .map(|name| name.file())
                .collect::<Vec<_>>(),
            expected_replay,
            "{file_name}: every present segment is replayed or re-listed"
        );

        let expected_tail = uint(expected, "materialized_upto_mseq");
        assert_eq!(plan.effective_tail, expected_tail, "{file_name}: effective tail");
    }
}

#[test]
fn lifecycle_vectors_span_the_required_shapes() {
    // The set is fixed above; this guards the semantic coverage the checker
    // also enforces: a fast-path vector, a replayed tail, an adopted tail and
    // a stale re-listing.
    let dir = lifecycle_dir();
    let mut fast = 0;
    let mut replay = 0;
    let mut adopted = 0;
    let mut stale = 0;
    for entry in fs::read_dir(dir).expect("lifecycle dir") {
        let path = entry.expect("entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
            continue;
        }
        let text = fs::read_to_string(&path).expect("read");
        let vector = pdsh_wal::json::parse(&text).expect("parse");
        let expected = vector.get("expected").expect("expected");
        if expected
            .get("fast_path")
            .and_then(|value| match value {
                Json::Bool(value) => Some(*value),
                _ => None,
            })
            .unwrap_or(false)
        {
            fast += 1;
        }
        if !strings(expected.get("adopted_tail_segments").expect("adopted"), "adopted").is_empty() {
            adopted += 1;
        }
        if !strings(expected.get("relisted_segments").expect("relisted"), "relisted").is_empty() {
            stale += 1;
        }
        if expected
            .get("replay_records")
            .and_then(Json::as_u64)
            .unwrap_or(0)
            > 0
        {
            replay += 1;
        }
    }
    assert!(fast >= 1, "no fast-path vector");
    assert!(replay >= 1, "no replayed-tail vector");
    assert!(adopted >= 1, "no adopted-tail vector");
    assert!(stale >= 1, "no re-listed vector");
}
