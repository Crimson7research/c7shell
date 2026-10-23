//! `tests/fixtures/tailscale/evidence.json` against the requirements and
//! their traceability: every requirement classified once, by the plan's
//! procedure, with the evidence each class needs.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use fake_tailscaled::corpus::Case;
use fake_tailscaled::evidence::{self, Evidence, KNOWN_NEEDS};
use fake_tailscaled::scenario::{EvidenceClass, Scenario, Tag, Verdict};
use fake_tailscaled::views::ViewTest;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}

fn read(rel: &str) -> String {
    std::fs::read_to_string(repo().join(rel)).unwrap_or_else(|e| panic!("{rel}: {e}"))
}

fn spec() -> String {
    read("docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md")
}

fn traceability() -> String {
    read("docs/superpowers/specs/2026-10-19-tailscale-rust-traceability.md")
}

fn loaded() -> Evidence {
    Evidence::load(&repo().join("tests/fixtures/tailscale/evidence.json")).unwrap()
}

#[test]
fn the_readers_find_the_spec_headings_and_table_b_rows() {
    let headings = evidence::spec_headings(&spec());
    assert_eq!(headings.len(), 154);
    assert_eq!(headings[0], ("R-HTTP-01".to_string(), "parity".to_string()));
    assert!(headings.contains(&("R-FAKE-07".to_string(), "kit".to_string())));
    let rows = evidence::table_b(&traceability());
    assert_eq!(
        rows["R-HTTP-01"],
        BTreeSet::from([
            "plugin/lib/tailscale/tests/tst_localapiclient.cpp::sendsAHostHeaderTailscaledAccepts".to_string()
        ])
    );
    assert!(rows["R-BOOT-01"].contains("tests/test-bootstrap.sh:434"));
    assert!(rows["R-FAKE-06"].contains("plugin/lib/testing/tests/tst_fakesocketserver.cpp::canKeepTheClientOpen"));
    // The line-range and helper tables refine rows already listed; they add none.
    assert!(!rows.values().flatten().any(|t| t.contains("::label") || t.ends_with(":1183-1188")));
    assert!(!rows.contains_key("R-HTTP-09"));
}

#[test]
fn every_requirement_is_classified_exactly_once_with_its_tag() {
    let ev = loaded();
    let ids: Vec<(String, String)> = ev.requirements.iter().map(|r| (r.id.clone(), r.tag.clone())).collect();
    let headings = evidence::spec_headings(&spec());
    assert_eq!(ids.len(), 154);
    assert_eq!(ids, headings, "the evidence file's ids and tags, in order, differ from the spec's headings");
    assert_eq!(ev.format, 1);
    assert_eq!(ev.source, "a38dbcae841a1134514f68cba8f5b98d4efddb68");
}

#[test]
fn none_and_fake_self_hold_exactly_their_requirements() {
    let ev = loaded();
    let of = |class: EvidenceClass| -> BTreeSet<&str> {
        ev.requirements.iter().filter(|r| r.class == class).map(|r| r.id.as_str()).collect()
    };
    let untracked: BTreeSet<&str> = ev
        .requirements
        .iter()
        .filter(|r| r.tag == "withdrawn" || r.tag == "follow-up")
        .map(|r| r.id.as_str())
        .collect();
    assert_eq!(of(EvidenceClass::None), untracked);
    assert_eq!(
        of(EvidenceClass::FakeSelf),
        BTreeSet::from(["R-FAKE-01", "R-FAKE-02", "R-FAKE-03", "R-FAKE-05", "R-FAKE-06", "R-FAKE-07"])
    );
}

#[test]
fn cpp_suite_entries_name_exactly_their_table_b_rows() {
    let ev = loaded();
    let rows = evidence::table_b(&traceability());
    let empty = BTreeSet::new();
    for r in &ev.requirements {
        let mapped = rows.get(&r.id).unwrap_or(&empty);
        if r.class == EvidenceClass::CppSuite {
            assert_eq!(r.tag, "parity", "{}: cpp-suite is for parity requirements", r.id);
            let tests: BTreeSet<String> = r.tests.iter().cloned().collect();
            assert_eq!(tests.len(), r.tests.len(), "{}: a test is named twice", r.id);
            assert!(!tests.is_empty(), "{}: a cpp-suite entry names its #286 tests", r.id);
            assert_eq!(&tests, mapped, "{}: tests differ from the Table B rows that map it", r.id);
        } else {
            assert!(r.tests.is_empty(), "{}: only a cpp-suite entry names tests at its top level", r.id);
        }
        for d in r.deferred.iter().filter(|d| d.class == EvidenceClass::CppSuite) {
            assert_eq!(r.tag, "parity", "{}: a cpp-suite clause belongs to a parity requirement", r.id);
            assert!(!d.tests.is_empty(), "{}: deferred `{}` names no test", r.id, d.clause);
            for t in &d.tests {
                assert!(
                    mapped.contains(t),
                    "{}: deferred `{}` names {t}, which Table B does not map to it",
                    r.id,
                    d.clause
                );
            }
        }
    }
}

#[test]
fn phase3_only_entries_say_why_they_cannot_run() {
    let ev = loaded();
    let rows = evidence::table_b(&traceability());
    for r in ev.requirements.iter().filter(|r| r.class == EvidenceClass::Phase3Only) {
        let reason = r.reason.as_deref().unwrap_or_else(|| panic!("{}: no reason", r.id));
        if r.tag == "parity" {
            assert!(!rows.contains_key(&r.id), "{}: a parity requirement with #286 tests is cpp-suite", r.id);
            assert!(reason.starts_with("no #286 test and cannot run on C++:"), "{}: {reason}", r.id);
        } else {
            assert!(reason.starts_with("cannot run on C++:"), "{}: {reason}", r.id);
        }
        assert!(!r.needs.is_empty(), "{}: a phase3-only entry names what it needs", r.id);
    }
    for r in ev.requirements.iter().filter(|r| r.class == EvidenceClass::CppSuite) {
        assert!(!r.needs.is_empty(), "{}: a cpp-suite entry names what it needs", r.id);
    }
}

#[test]
fn harness_on_cpp_entries_say_what_runs_and_what_is_deferred() {
    let ev = loaded();
    for r in ev.requirements.iter().filter(|r| r.class == EvidenceClass::HarnessOnCpp) {
        assert!(r.tag == "parity" || r.tag == "fix", "{}: harness-on-cpp is for parity and fix", r.id);
        assert!(r.needs.is_empty(), "{}: what runs on C++ needs nothing", r.id);
        assert!(r.runs.as_deref().is_some_and(|s| !s.trim().is_empty()), "{}: say which clauses run", r.id);
        assert!(matches!(r.pr, Some(306..=309)), "{}: name the Phase 2 PR (306 to 309) whose scenarios run it", r.id);
        assert!(r.reason.is_none(), "{}: a reason is for phase3-only", r.id);
    }
    for r in &ev.requirements {
        for d in &r.deferred {
            assert!(!d.clause.trim().is_empty(), "{}: a deferred clause names itself", r.id);
            match d.class {
                EvidenceClass::HarnessOnCpp => {
                    assert!(d.needs.is_empty(), "{}: deferred `{}` runs on C++, so it needs nothing", r.id, d.clause);
                    assert!(matches!(d.pr, Some(306..=309)), "{}: deferred `{}` names its PR", r.id, d.clause);
                }
                EvidenceClass::CppSuite => assert!(!d.needs.is_empty(), "{}: `{}` names its needs", r.id, d.clause),
                EvidenceClass::Phase3Only => {
                    assert!(!d.needs.is_empty(), "{}: `{}` names its needs", r.id, d.clause);
                    assert!(d.reason.as_deref().is_some_and(|s| !s.is_empty()), "{}: `{}` says why", r.id, d.clause);
                }
                other => panic!("{}: deferred `{}` has class {other:?}", r.id, d.clause),
            }
        }
        if matches!(r.class, EvidenceClass::None) {
            assert!(r.deferred.is_empty() && r.needs.is_empty(), "{}: an untracked requirement carries nothing", r.id);
        }
    }
}

#[test]
fn every_need_is_known() {
    let ev = loaded();
    for r in &ev.requirements {
        for n in r.needs.iter().chain(r.deferred.iter().flat_map(|d| d.needs.iter())) {
            assert!(KNOWN_NEEDS.contains(&n.as_str()), "{}: unknown need `{n}`", r.id);
        }
    }
}

/// The snake-case form of a camelCase test function name.
fn snake(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_uppercase() {
            out.push('_');
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

#[test]
fn every_fake_requirement_has_its_tests() {
    let tests_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut source = String::new();
    for entry in std::fs::read_dir(&tests_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "rs") {
            source += &std::fs::read_to_string(&path).unwrap();
        }
    }
    let ev = loaded();
    for r in ev.requirements.iter().filter(|r| r.class == EvidenceClass::FakeSelf) {
        let prefix = format!("fn {}_", r.id.to_lowercase().replace('-', "_"));
        assert!(source.contains(&prefix), "{}: no `{prefix}...` test under tests/", r.id);
    }
    let before = evidence::table_b_section(&traceability(), "tests from before #286");
    let ported: Vec<&String> = before.get("R-FAKE-06").map(|s| s.iter().collect()).unwrap_or_default();
    assert_eq!(ported.len(), 11);
    for t in ported {
        let function = t.rsplit("::").next().unwrap();
        let want = format!("fn r_fake_06_{}()", snake(function));
        assert!(source.contains(&want), "R-FAKE-06: {t} is not ported as `{want}`");
    }
}

#[test]
fn scenarios_agree_with_the_evidence() {
    let ev = loaded();
    let by_id: BTreeMap<&str, &evidence::Entry> = ev.requirements.iter().map(|r| (r.id.as_str(), r)).collect();
    let dir = repo().join("tests/fixtures/tailscale/scenarios");
    let mut covered = BTreeSet::new();
    for entry in std::fs::read_dir(&dir).into_iter().flatten() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let s = Scenario::load(&path).unwrap();
        for id in &s.requirements {
            let e = by_id.get(id.as_str()).unwrap_or_else(|| panic!("{}: unknown requirement {id}", s.id));
            let classes: Vec<EvidenceClass> =
                std::iter::once(e.class).chain(e.deferred.iter().map(|d| d.class)).collect();
            assert!(
                classes.contains(&s.evidence),
                "{}: evidence {:?} is not {id}'s class or a deferred clause's",
                s.id,
                s.evidence
            );
            // As for a corpus case: a fix scenario runs what #286 does not
            // do, so it names only fix requirements; a parity scenario may
            // run a clause of a fix requirement that #286 already meets.
            if s.tag == Tag::Fix {
                assert_eq!(e.tag, "fix", "{}: a fix scenario names {id}, a {} requirement", s.id, e.tag);
            } else {
                assert!(e.tag == "parity" || e.tag == "fix", "{}: a parity scenario names {id}, a {}", s.id, e.tag);
            }
            covered.insert(id.clone());
        }
        if s.evidence == EvidenceClass::HarnessOnCpp {
            let d = &s.on["cpp-286"];
            assert!(
                matches!(d.result, Verdict::Pass | Verdict::Fail),
                "{}: a harness-on-cpp scenario runs on cpp-286",
                s.id
            );
        }
    }
    for r in ev.requirements.iter().filter(|r| r.class == EvidenceClass::HarnessOnCpp && r.pr == Some(306)) {
        assert!(covered.contains(&r.id), "{}: assigned to #306, but no scenario runs it", r.id);
    }
}

/// The requirements committed tests name: the scenarios', the corpus
/// cases' and the view tests', or with `views_only` the view tests' alone.
fn named_by_tests(views_only: bool) -> BTreeSet<String> {
    let fixtures = repo().join("tests/fixtures/tailscale");
    let mut named = BTreeSet::new();
    for entry in std::fs::read_dir(fixtures.join("views")).into_iter().flatten() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            named.extend(ViewTest::read(&path).unwrap().requirements);
        }
    }
    if views_only {
        return named;
    }
    for entry in std::fs::read_dir(fixtures.join("scenarios")).into_iter().flatten() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            named.extend(Scenario::load(&path).unwrap().requirements);
        }
    }
    let cases = Case::load_dir(&fixtures.join("corpus"), fake_tailscaled::scenario::IMPLEMENTATIONS).unwrap();
    named.extend(cases.into_iter().flat_map(|c| c.requirements));
    named
}

/// The requirements Phase 2 PR `pr` runs on a38dbca, by an entry or a
/// deferred clause, that no test in `named` names.
fn not_run_by(pr: u32, named: &BTreeSet<String>) -> Vec<String> {
    let runs_in = |r: &&evidence::Entry| {
        (r.class == EvidenceClass::HarnessOnCpp && r.pr == Some(pr))
            || r.deferred.iter().any(|d| d.class == EvidenceClass::HarnessOnCpp && d.pr == Some(pr))
    };
    loaded().requirements.iter().filter(runs_in).map(|r| r.id.clone()).filter(|id| !named.contains(id)).collect()
}

/// The requirements Phase 2 PR `pr` runs on a38dbca that no committed
/// scenario, corpus case or view test names.
fn not_run_by_a_test(pr: u32) -> Vec<String> {
    not_run_by(pr, &named_by_tests(false))
}

/// Every requirement #307 runs on a38dbca is named by a scenario or a
/// corpus case.
#[test]
fn every_requirement_of_307_has_a_scenario_or_a_corpus_case() {
    let missing = not_run_by_a_test(307);
    assert!(missing.is_empty(), "assigned to #307, but no scenario or corpus case runs: {missing:?}");
}

/// Every requirement #308 runs on a38dbca, R-FAKE-03's backend half
/// included, is named by a scenario.
#[test]
fn every_requirement_of_308_has_a_scenario() {
    let missing = not_run_by_a_test(308);
    assert!(missing.is_empty(), "assigned to #308, but no scenario runs: {missing:?}");
}

/// Every requirement #309 runs on a38dbca is named by a view test: the
/// deferred view halves too (R-GROUP-06, R-WRITE-09, R-UI-15), whose
/// requirements #307's and #308's scenarios already name.
#[test]
fn every_requirement_of_309_has_a_view_test() {
    let missing = not_run_by(309, &named_by_tests(true));
    assert!(missing.is_empty(), "assigned to #309, but no view test runs: {missing:?}");
}

#[test]
fn the_reader_finds_table_c_rows() {
    let text = "## Table B\n\n| Requirement | Class | Scenarios | Corpus cases |\n|---|---|---|---|\n\
                | R-X-01 | `cpp-suite` | `b` | — |\n\n## Table C: harness\n\n\
                | Requirement | Class | Scenarios | Corpus cases | Notes |\n|---|---|---|---|---|\n\
                | R-HTTP-02 | `harness-on-cpp` | `http-02-a`, `http-02-b` | — | see R-HTTP-01 |\n\
                | R-PARSE-10 | `none` | — | `c` | |\n\n## After\n\n| R-Y-01 | `none` | `d` | — |\n";
    let rows = evidence::table_c(text);
    let set = |ids: &[&str]| ids.iter().map(|s| s.to_string()).collect::<BTreeSet<String>>();
    assert_eq!(
        rows,
        vec![
            evidence::HarnessRow {
                id: "R-HTTP-02".into(),
                class: "harness-on-cpp".into(),
                scenarios: set(&["http-02-a", "http-02-b"]),
                corpus: set(&[]),
            },
            evidence::HarnessRow {
                id: "R-PARSE-10".into(),
                class: "none".into(),
                scenarios: set(&[]),
                corpus: set(&["c"])
            },
        ]
    );
}

/// The ids of the committed scenarios and corpus cases, by each
/// requirement they name.
fn tests_by_requirement() -> (BTreeMap<String, BTreeSet<String>>, BTreeMap<String, BTreeSet<String>>) {
    let fixtures = repo().join("tests/fixtures/tailscale");
    let mut scenarios: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for entry in std::fs::read_dir(fixtures.join("scenarios")).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            let s = Scenario::load(&path).unwrap();
            for id in s.requirements {
                scenarios.entry(id).or_default().insert(s.id.clone());
            }
        }
    }
    let mut corpus: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for c in Case::load_dir(&fixtures.join("corpus"), fake_tailscaled::scenario::IMPLEMENTATIONS).unwrap() {
        for id in c.requirements {
            corpus.entry(id).or_default().insert(c.id.clone());
        }
    }
    (scenarios, corpus)
}

/// Table C lists every requirement of the areas #307 and #308 run (R-HTTP,
/// R-PARSE, R-GROUP, R-WATCH, R-CONN, R-WRITE, R-UI, R-SEC and R-BOOT) once,
/// in order, with its evidence class and exactly the scenarios and corpus
/// cases that name it.
#[test]
fn table_c_lists_the_harness_tests_of_each_requirement_of_its_areas() {
    let ev = loaded();
    let (scenarios, corpus) = tests_by_requirement();
    let empty = BTreeSet::new();
    let areas = ["R-HTTP-", "R-PARSE-", "R-GROUP-", "R-WATCH-", "R-CONN-", "R-WRITE-", "R-UI-", "R-SEC-", "R-BOOT-"];
    let want: Vec<evidence::HarnessRow> = ev
        .requirements
        .iter()
        .filter(|r| areas.iter().any(|a| r.id.starts_with(a)))
        .map(|r| evidence::HarnessRow {
            id: r.id.clone(),
            class: serde_json::to_value(r.class).unwrap().as_str().unwrap().to_string(),
            scenarios: scenarios.get(&r.id).unwrap_or(&empty).clone(),
            corpus: corpus.get(&r.id).unwrap_or(&empty).clone(),
        })
        .collect();
    let got = evidence::table_c(&traceability());
    assert_eq!(got.len(), want.len(), "Table C has {} rows, want {}", got.len(), want.len());
    for (g, w) in got.iter().zip(&want) {
        assert_eq!(g, w, "Table C's row for {} differs from evidence.json and the test files", w.id);
    }
}

/// A corpus case runs harness-on-cpp clauses of the requirements it names.
/// A `fix` case expects what #286 does not do, so every requirement it
/// names is a `fix` one; a `parity` case may name a `fix` requirement whose
/// clause #286 already meets.
#[test]
fn corpus_cases_agree_with_the_evidence() {
    let ev = loaded();
    let by_id: BTreeMap<&str, &evidence::Entry> = ev.requirements.iter().map(|r| (r.id.as_str(), r)).collect();
    let dir = repo().join("tests/fixtures/tailscale/corpus");
    let cases =
        if dir.exists() { Case::load_dir(&dir, fake_tailscaled::scenario::IMPLEMENTATIONS).unwrap() } else { vec![] };
    for c in &cases {
        for id in &c.requirements {
            let e = by_id.get(id.as_str()).unwrap_or_else(|| panic!("{}: unknown requirement {id}", c.id));
            let runs_here = e.class == EvidenceClass::HarnessOnCpp
                || e.deferred.iter().any(|d| d.class == EvidenceClass::HarnessOnCpp);
            assert!(runs_here, "{}: {id} has no harness-on-cpp clause", c.id);
            if c.tag == Tag::Fix {
                assert_eq!(e.tag, "fix", "{}: a fix case names {id}, a {} requirement", c.id, e.tag);
            }
        }
        let d = &c.on["cpp-286"];
        assert!(matches!(d.result, Verdict::Pass | Verdict::Fail), "{}: a corpus case runs on cpp-286", c.id);
    }
}

#[test]
fn the_loader_rejects_a_malformed_file() {
    let dir = std::env::temp_dir().join(format!("ev-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("evidence.json");
    std::fs::write(
        &path,
        r#"{"format":1,"source":"x","decided":"d","requirements":[{"id":"R-X-01","tag":"parity","class":"nope"}]}"#,
    )
    .unwrap();
    assert!(Evidence::load(&path).is_err());
    std::fs::write(&path, r#"{"format":1,"source":"x","decided":"d","requirements":[],"extra":1}"#).unwrap();
    assert!(Evidence::load(&path).unwrap_err().contains("extra"));
    std::fs::remove_dir_all(&dir).unwrap();
}
