//! The committed baseline (`tests/fixtures/tailscale/mutation/baseline.json`,
//! plan decision M7): of a38dbca, every target mutated, its summary its
//! entries', every survivor accounted for, each added killing test a real
//! one, and the score at least the 70% gate.

use std::path::{Path, PathBuf};

use mutate_cpp::record::{Outcome, Record};
use mutate_cpp::targets::TARGETS;

const SOURCE: &str = "a38dbcae841a1134514f68cba8f5b98d4efddb68";

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn baseline() -> Record {
    let path = repo().join("tests/fixtures/tailscale/mutation/baseline.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn it_is_of_a38dbca_and_mutates_every_target() {
    let r = baseline();
    assert_eq!(r.source, SOURCE);
    assert_eq!(r.kill_suite, ["qttest", "scenarios", "corpus"]);
    for t in TARGETS {
        assert!(r.mutants.iter().any(|m| m.file == t.file), "no mutant of {}", t.file);
    }
    let mut ids: Vec<&str> = r.mutants.iter().map(|m| m.id.as_str()).collect();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), r.mutants.len(), "a mutant recorded twice");
}

/// Every site of a38dbca's targets is recorded, and the score of the suite
/// as #286's characterisation left it stays what the baseline run measured:
/// a run stopped part-way, or a rerun that lost an added kill's name, moves
/// one of these. 297 is the count `mutate-cpp run` finds at a38dbca (123,
/// 27, 46, 99 and 2, in the order of TARGETS); 192 is what the baseline run
/// killed before this PR added any test.
#[test]
fn it_is_complete_and_keeps_the_baseline_it_measured() {
    let s = baseline().summary();
    assert_eq!(s.mutants, 297, "the record holds {} of a38dbca's 297 mutants", s.mutants);
    assert_eq!(s.killed + s.timeout - s.killed_by_added, 192, "the baseline's kills moved: {s:?}");
}

#[test]
fn its_summary_is_its_entries() {
    let r = baseline();
    assert_eq!(r.summary, r.summary(), "the stored summary differs from the entries");
}

/// A survivor has a reason; a mutant killed, or timed out, only by a test
/// this PR added names it; neither annotation sits anywhere else.
#[test]
fn every_survivor_has_a_reason_and_every_added_kill_its_test() {
    let r = baseline();
    assert!(r.unaccounted().is_empty(), "survivors with no reason: {:?}", r.unaccounted());
    let misplaced: Vec<&str> = r
        .mutants
        .iter()
        .filter(|m| {
            let killed = matches!(m.outcome, Outcome::Killed { .. } | Outcome::Timeout { .. });
            (m.reason.is_some() && m.outcome != Outcome::Survived) || (m.killed_by_added.is_some() && !killed)
        })
        .map(|m| m.id.as_str())
        .collect();
    assert!(misplaced.is_empty(), "a reason off a survivor, or an added kill off a killed mutant: {misplaced:?}");
}

/// An added killing test is `scenario <id>` or `corpus <id>`, a committed
/// file, and it is the test the kill names; a timeout names no test, so it
/// is in the step that runs that kind.
#[test]
fn each_added_killing_test_exists_and_is_the_one_that_kills() {
    let fixtures = repo().join("tests/fixtures/tailscale");
    for m in baseline().mutants {
        let Some(test) = &m.killed_by_added else { continue };
        let path = match test.split_once(' ') {
            Some(("scenario", id)) => fixtures.join(format!("scenarios/{id}.json")),
            Some(("corpus", id)) => fixtures.join(format!("corpus/{id}.json")),
            _ => panic!("{}: `{test}` is neither `scenario <id>` nor `corpus <id>`", m.id),
        };
        assert!(path.is_file(), "{}: {} does not exist", m.id, path.display());
        let (kind, id) = test.split_once(' ').unwrap_or_default();
        match &m.outcome {
            Outcome::Killed { detail, .. } => {
                assert!(detail.contains(id), "{}: killed by `{detail}`, not by {test}", m.id)
            }
            Outcome::Timeout { step } => {
                let want = if kind == "scenario" { "scenarios" } else { "corpus" };
                assert_eq!(step, want, "{}: timed out in `{step}`, which does not run {test}", m.id);
            }
            _ => unreachable!("checked above"),
        }
    }
}

#[test]
fn the_score_is_at_least_the_gate() {
    let s = baseline().summary();
    assert!(s.score >= 0.70, "the mutation score is {:.3}, under the 70% gate", s.score);
}
