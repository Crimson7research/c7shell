//! The record (plan decision M7): its summary and score, what accounts for
//! a survivor, and loading it back.

use mutate_cpp::record::{Entry, Outcome, Record};

fn entry(id: &str, outcome: Outcome) -> Entry {
    Entry {
        id: id.into(),
        file: "f.cpp".into(),
        line: 1,
        col: 1,
        kind: "Binary".into(),
        from: "==".into(),
        to: "!=".into(),
        outcome,
        reason: None,
        killed_by_added: None,
    }
}

fn record() -> Record {
    let mut r = Record::new("abc", &["ctest".to_string()]);
    r.mutants = vec![
        entry("k1", Outcome::Killed { step: "ctest".into(), detail: "FAIL x".into() }),
        entry("k2", Outcome::Killed { step: "ctest".into(), detail: "FAIL y".into() }),
        entry("t", Outcome::Timeout { step: "ctest".into() }),
        entry("s", Outcome::Survived),
        entry("b", Outcome::BuildFailed { detail: "error".into() }),
    ];
    r
}

#[test]
fn the_score_counts_timeouts_as_killed_and_leaves_out_what_did_not_build() {
    let s = record().summary();
    assert_eq!((s.mutants, s.killed, s.timeout, s.survived, s.build_failed), (5, 2, 1, 1, 1));
    assert!((s.score - 0.75).abs() < 1e-9, "{}", s.score);
    assert!((s.baseline_score - 0.75).abs() < 1e-9, "{}", s.baseline_score);
}

#[test]
fn the_baseline_score_leaves_out_the_kills_only_an_added_test_makes() {
    let mut r = record();
    r.mutants[1].killed_by_added = Some("scenario x".into());
    let s = r.summary();
    assert_eq!(s.killed_by_added, 1);
    assert!((s.score - 0.75).abs() < 1e-9 && (s.baseline_score - 0.5).abs() < 1e-9, "{s:?}");
}

#[test]
fn a_survivor_is_accounted_for_by_a_reason() {
    let mut r = record();
    assert_eq!(r.unaccounted(), ["s"]);
    r.mutants[3].reason = Some("equivalent: the order is the same either way".into());
    assert!(r.unaccounted().is_empty());
    r.mutants[3].reason = Some("  ".into());
    assert_eq!(r.unaccounted(), ["s"], "a blank reason accounts for nothing");
}

#[test]
fn it_saves_and_loads_with_its_summary_and_refuses_another_source() {
    let dir = std::env::temp_dir().join(format!("mutate-cpp-record-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("r.json");
    let r = record();
    r.save(&path).unwrap();
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("\"score\": 0.75"), "{text}");
    let back = Record::load_or_new(&path, "abc", &["ctest".to_string()]).unwrap();
    assert_eq!(back.mutants, r.mutants);
    let other = Record::load_or_new(&path, "def", &["ctest".to_string()]).unwrap_err();
    assert!(other.contains("abc") && other.contains("def"), "{other}");
    let fresh = Record::load_or_new(&dir.join("none.json"), "abc", &[]).unwrap();
    assert!(fresh.mutants.is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn it_refuses_a_record_of_another_kill_suite() {
    let dir = std::env::temp_dir().join(format!("mutate-cpp-suite-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("r.json");
    record().save(&path).unwrap();
    let e = Record::load_or_new(&path, "abc", &["ctest".to_string(), "scenarios".to_string()]).unwrap_err();
    assert!(e.contains("ctest") && e.contains("scenarios"), "{e}");
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A mutant run again keeps the annotation its new outcome can carry: a
/// survivor its reason, a kill or a timeout the added test that makes it.
#[test]
fn a_rerun_keeps_the_annotations_its_new_outcome_can_carry() {
    let mut old = record();
    old.mutants[0].killed_by_added = Some("scenario x".into());
    old.mutants[3].reason = Some("equivalent: why".into());
    old.mutants[2].killed_by_added = Some("scenario t".into());
    let mut r = record();
    r.mutants[2].outcome = Outcome::Survived;
    r.carry(&old.mutants);
    assert_eq!(r.mutants[0].killed_by_added.as_deref(), Some("scenario x"));
    assert_eq!(r.mutants[3].reason.as_deref(), Some("equivalent: why"));
    assert_eq!(r.mutants[2].killed_by_added, None, "a survivor carries no added kill");
    assert_eq!(r.mutants[2].reason, None, "and no reason it never had");
}
