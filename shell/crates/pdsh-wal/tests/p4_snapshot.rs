// SPDX-License-Identifier: MIT
//! Temporary evidence harness: plan recovery on P4's real bricked workspace.
mod common;

use std::path::Path;

use common::crc32c;
use pdsh_wal::{
    scan_segment, Manifest, RecoveryInput, RecoveryPlan, SegmentFacts, SegmentName,
};

#[test]
#[ignore = "set PDSH_P4_SNAPSHOT to the extracted P4 wal/ snapshot"]
fn p4_snapshot_plans_cleanly() {
    let snapshot =
        std::env::var("PDSH_P4_SNAPSHOT").expect("set PDSH_P4_SNAPSHOT to the snapshot dir");
    let root = Path::new(&snapshot);
    let manifest = Manifest::parse(
        &std::fs::read_to_string(root.join("manifest.json")).expect("manifest"),
    )
    .expect("manifest parses");
    let mut facts = Vec::new();
    for entry in std::fs::read_dir(root.join("wal")).expect("wal dir") {
        let entry = entry.expect("entry");
        let file = entry.file_name().to_string_lossy().into_owned();
        let name = SegmentName::parse(&file).expect("segment name");
        let bytes = std::fs::read(entry.path()).expect("segment bytes");
        let scan = scan_segment(&bytes, &crc32c);
        assert!(!scan.is_corrupt(), "{file} corrupt: {:?}", scan.verdict);
        assert!(scan.header_ok(), "{file} header");
        facts.push(SegmentFacts::from_scan(name, &scan));
    }
    let plan = RecoveryPlan::plan(RecoveryInput::new(facts, Some(manifest), false));
    eprintln!(
        "P4 PLAN: fail={:?} adopt={:?} effective_tail={} next_mseq={} next_epoch={}",
        plan.fail, plan.adopt, plan.effective_tail, plan.next_mseq, plan.next_epoch
    );
    assert!(plan.is_ok(), "P4 snapshot must recover: {:?}", plan.fail);
    assert_eq!(plan.next_mseq, 583);
    assert_eq!(plan.effective_tail, 582);
}
