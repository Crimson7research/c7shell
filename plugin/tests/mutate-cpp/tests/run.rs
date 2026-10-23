//! The runner on a project of plain files whose build and test steps are
//! shell commands: each outcome, the file restored after every mutant, a
//! stale site refused, and a run that resumes from its record.

use std::fs;
use std::path::{Path, PathBuf};

use mutate_cpp::record::{Outcome, Record};
use mutate_cpp::run::{run_all, run_mutant, Mutant, Pipeline, Step, Worker};

/// A private directory, removed when dropped.
struct Dir(PathBuf);

impl Dir {
    fn new(name: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("mutate-cpp-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(p.join("tree")).unwrap();
        fs::create_dir_all(p.join("build")).unwrap();
        Dir(p)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const SOURCE: &str = "check a == b\nlimit 3\n";

fn worker(d: &Dir) -> Worker {
    fs::write(d.0.join("tree/a.txt"), SOURCE).unwrap();
    Worker { tree: d.0.join("tree"), build: d.0.join("build") }
}

fn sh(script: &str) -> Vec<String> {
    vec!["sh".into(), "-c".into(), script.into()]
}

/// Builds unless the file holds `broken`; the test step fails on `!=`; the
/// slow step never ends when the limit is 4.
fn pipeline() -> Pipeline {
    Pipeline {
        build: sh("! grep -q broken {tree}/a.txt"),
        build_timeout_s: 30,
        steps: vec![
            Step {
                name: "fast".into(),
                argv: sh("if grep -q '!=' {tree}/a.txt; then echo 'FAIL equality'; exit 1; fi"),
                timeout_s: 30,
            },
            Step {
                name: "slow".into(),
                argv: sh("if grep -q 'limit 4' {tree}/a.txt; then exec tail -f /dev/null; fi"),
                timeout_s: 1,
            },
        ],
    }
}

fn mutant(offset: usize, from: &str, to: &str) -> Mutant {
    Mutant {
        id: format!("a.txt:{offset}:{to}"),
        file: "a.txt".into(),
        line: 1,
        col: 1,
        offset,
        kind: "Binary".into(),
        from: from.into(),
        to: to.into(),
    }
}

fn restored(w: &Worker) -> bool {
    fs::read_to_string(w.tree.join("a.txt")).unwrap() == SOURCE
}

#[test]
fn a_mutant_a_test_fails_on_is_killed_by_that_step_with_its_line() {
    let d = Dir::new("killed");
    let w = worker(&d);
    let got = run_mutant(&w, &mutant(8, "==", "!="), &pipeline()).unwrap();
    assert_eq!(got, Outcome::Killed { step: "fast".into(), detail: "FAIL equality".into() });
    assert!(restored(&w));
}

#[test]
fn a_step_that_fails_once_and_then_passes_is_flaky_and_stops_the_run() {
    let d = Dir::new("flaky");
    let w = worker(&d);
    let marker = d.0.join("failed-once");
    let flaky = Pipeline {
        build: sh("true"),
        build_timeout_s: 30,
        steps: vec![Step {
            name: "flaky".into(),
            argv: sh(&format!("if [ ! -e {m} ]; then touch {m}; echo 'FAIL once'; exit 1; fi", m = marker.display())),
            timeout_s: 30,
        }],
    };
    let e = run_mutant(&w, &mutant(8, "==", "!="), &flaky).unwrap_err();
    assert!(e.contains("flaky") && e.contains("FAIL once"), "{e}");
    assert!(restored(&w));
}

#[test]
fn a_mutant_no_step_fails_on_survives() {
    let d = Dir::new("survived");
    let w = worker(&d);
    assert_eq!(run_mutant(&w, &mutant(19, "3", "5"), &pipeline()).unwrap(), Outcome::Survived);
    assert!(restored(&w));
}

#[test]
fn a_step_past_its_timeout_is_a_timeout() {
    let d = Dir::new("timeout");
    let w = worker(&d);
    assert_eq!(run_mutant(&w, &mutant(19, "3", "4"), &pipeline()).unwrap(), Outcome::Timeout { step: "slow".into() });
    assert!(restored(&w));
}

#[test]
fn a_mutant_that_does_not_build_is_build_failed() {
    let d = Dir::new("build");
    let w = worker(&d);
    let got = run_mutant(&w, &mutant(6, "a", "broken"), &pipeline()).unwrap();
    assert!(matches!(got, Outcome::BuildFailed { .. }), "{got:?}");
    assert!(restored(&w));
}

#[test]
fn a_site_whose_text_moved_is_refused_and_nothing_is_written() {
    let d = Dir::new("stale");
    let w = worker(&d);
    let e = run_mutant(&w, &mutant(7, "==", "!="), &pipeline()).unwrap_err();
    assert!(e.contains("a.txt") && e.contains("=="), "{e}");
    assert!(restored(&w));
}

fn record_at(path: &Path) -> Record {
    Record::load_or_new(path, "src", &["fast".to_string(), "slow".to_string()]).unwrap()
}

#[test]
fn run_all_records_every_mutant_across_workers_and_resumes() {
    let d1 = Dir::new("all-1");
    let d2 = Dir::new("all-2");
    let workers = vec![worker(&d1), worker(&d2)];
    let path = d1.0.join("record.json");
    let mutants = vec![mutant(8, "==", "!="), mutant(19, "3", "5"), mutant(19, "3", "4")];
    let mut record = record_at(&path);
    run_all(&workers, &mutants[..2], &pipeline(), &mut record, &path).unwrap();
    let saved = record_at(&path);
    assert_eq!(saved.mutants.len(), 2);
    let mut record = saved;
    let ran = run_all(&workers, &mutants, &pipeline(), &mut record, &path).unwrap();
    assert_eq!(ran, 1, "only the mutant not yet recorded runs");
    let saved = record_at(&path);
    let outcomes: Vec<(&str, &Outcome)> = saved.mutants.iter().map(|m| (m.id.as_str(), &m.outcome)).collect();
    assert_eq!(outcomes.len(), 3);
    assert!(outcomes.contains(&("a.txt:19:4", &Outcome::Timeout { step: "slow".into() })));
    assert!(workers.iter().all(restored));
}
