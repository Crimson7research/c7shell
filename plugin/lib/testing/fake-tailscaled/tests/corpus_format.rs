//! The parser corpus format: one case per status body, with the contract
//! members and model rows it must publish, turned into a scenario the
//! harness runs. What it accepts, what it rejects, the scenario it makes,
//! and that every committed case validates.

mod support;

use std::path::{Path, PathBuf};

use fake_tailscaled::corpus::{apply_edits, Case, Edit};
use fake_tailscaled::scenario::{Scenario, Step, Wait};
use fake_tailscaled::Request;
use serde_json::{json, Value};
use support::TestDir;

const PREFS: &str = r#"{"WantRunning":true,"ExitNodeID":""}"#;
const CAPTURE: &str = "{\n  \"BackendState\": \"Running\",\n  \"Peer\": {}\n}\n";

/// A fixture root, laid out as `tests/fixtures/tailscale/` is: the default
/// prefs capture, one status capture and a `corpus/` directory.
fn root() -> TestDir {
    let dir = TestDir::new();
    std::fs::create_dir_all(dir.join("captures")).unwrap();
    std::fs::create_dir_all(dir.join("corpus")).unwrap();
    std::fs::write(dir.join("captures/prefs.json"), PREFS).unwrap();
    std::fs::write(dir.join("captures/status.json"), CAPTURE).unwrap();
    dir
}

/// A case with every field: a status from a capture with one edit, a
/// suggestion, contract members and both models' rows.
fn full() -> Value {
    json!({
        "format": 1,
        "id": "full",
        "requirements": ["R-PARSE-09", "R-GROUP-04"],
        "tag": "fix",
        "clauses": ["every field"],
        "deferred": ["nothing"],
        "status": { "file": "captures/status.json" },
        "edits": [ { "op": "add", "path": "/Peer/n", "value": { "ID": "nX1CNTRL", "HostName": "x" } } ],
        "suggest": { "json": { "ID": "nX1CNTRL" } },
        "expect": {
            "contract": { "state": { "enum": "Running" }, "recommendedExitNodeId": "nX1CNTRL", "issues": [] },
            "peers": [ { "nodeId": "nX1CNTRL", "displayName": "x" } ],
            "exitNodes": []
        },
        "on": {
            "cpp-286": { "result": "fail", "failing": [ { "id": "peers[0]", "actual": { "nodeId": "", "displayName": "" } } ],
                         "reason": "a defect" },
            "rust": { "result": "pass" }
        }
    })
}

/// A case with only what is required: a status given inline.
fn minimal() -> Value {
    json!({
        "format": 1,
        "id": "minimal",
        "requirements": ["R-PARSE-02"],
        "tag": "parity",
        "clauses": ["the tailnet name"],
        "status": { "json": { "BackendState": "Running", "CurrentTailnet": { "Name": "example.com" } } },
        "expect": { "contract": { "tailnet": "example.com" } },
        "on": { "cpp-286": { "result": "pass" }, "rust": { "result": "pass" } }
    })
}

fn write(dir: &TestDir, stem: &str, value: &Value) -> PathBuf {
    let path = dir.join(format!("corpus/{stem}.json"));
    std::fs::write(&path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    path
}

fn load(value: &Value) -> Result<Case, String> {
    let dir = root();
    Case::load(&write(&dir, value["id"].as_str().unwrap_or("x"), value))
}

fn rejected(value: Value) -> String {
    match load(&value) {
        Ok(_) => panic!("accepted: {value}"),
        Err(e) => e,
    }
}

fn assert_names(error: &str, field: &str) {
    assert!(error.contains(field), "the error does not name `{field}`: {error}");
}

/// The bytes the scenario's rule for `target` answers with.
fn body_for(s: &Scenario, target: &str) -> Vec<u8> {
    let head = format!("GET {target} HTTP/1.1\r\nHost: local-tailscaled.sock");
    let request = Request::new(1, 1, head.as_bytes(), b"\r\n\r\n", b"");
    let rule =
        s.fake.rules.iter().find(|r| r.matcher.matches(&request)).unwrap_or_else(|| panic!("no rule for {target}"));
    rule.reply.as_ref().unwrap_or_else(|| panic!("{target} has no reply")).body.0.clone()
}

fn expect_ids(s: &Scenario) -> Vec<String> {
    s.expects().map(|e| e.id.clone()).collect()
}

#[test]
fn it_makes_a_scenario_of_the_case() {
    let case = load(&full()).unwrap();
    let s = case.scenario();
    assert_eq!(s.id, "full");
    assert_eq!(s.requirements, ["R-PARSE-09", "R-GROUP-04"]);
    assert!(s.needs.is_empty());
    assert_eq!(format!("{:?}", s.evidence), "HarnessOnCpp");
    assert_eq!(
        expect_ids(s),
        [
            "contract.issues",
            "contract.recommendedExitNodeId",
            "contract.state",
            "peers.count",
            "peers[0]",
            "exitNodes.count"
        ]
    );
    assert!(matches!(s.steps[0], Step::Start(_)));
    match &s.steps[1] {
        Step::Wait(Wait::Contract(v)) => {
            assert_eq!(json!(v), json!({ "wantRunning": true, "state": { "enum": "Running" } }))
        }
        other => panic!("the snapshot wait is {other:?}"),
    }
    match &s.steps[2] {
        Step::Wait(Wait::Signal(w)) => assert_eq!((w.name.as_str(), w.at_least), ("recommendedExitNodeIdChanged", 1)),
        other => panic!("the suggestion wait is {other:?}"),
    }
}

#[test]
fn it_answers_the_opening_pass_from_the_case() {
    let case = load(&full()).unwrap();
    let s = case.scenario();
    let status: Value = serde_json::from_slice(&body_for(s, "/localapi/v0/status")).unwrap();
    assert_eq!(status, json!({ "BackendState": "Running", "Peer": { "n": { "ID": "nX1CNTRL", "HostName": "x" } } }));
    assert_eq!(body_for(s, "/localapi/v0/prefs"), PREFS.as_bytes());
    assert_eq!(body_for(s, "/localapi/v0/suggest-exit-node"), br#"{"ID":"nX1CNTRL"}"#);
    let watch = s.fake.rules.iter().find(|r| r.stream.is_some()).expect("a watch stream rule");
    assert!(watch.matcher.target.as_deref().is_some_and(|t| t.starts_with("/localapi/v0/watch-ipn-bus")));
}

#[test]
fn a_capture_without_edits_is_served_unchanged() {
    let mut v = full();
    v.as_object_mut().unwrap().remove("edits");
    let case = load(&v).unwrap();
    assert_eq!(body_for(case.scenario(), "/localapi/v0/status"), CAPTURE.as_bytes());
}

#[test]
fn without_a_suggestion_it_answers_none_and_waits_for_none() {
    let case = load(&minimal()).unwrap();
    let s = case.scenario();
    assert_eq!(body_for(s, "/localapi/v0/suggest-exit-node"), b"{}");
    assert_eq!(s.steps.len(), 3);
    assert_eq!(expect_ids(s), ["contract.tailnet"]);
}

#[test]
fn edits_add_replace_and_remove() {
    let mut v = json!({ "a": { "b": 1, "c": [1, 2] }, "k/~": 0 });
    let edits: Vec<Edit> = serde_json::from_value(json!([
        { "op": "add", "path": "/a/d", "value": "new" },
        { "op": "add", "path": "/a/c/-", "value": 3 },
        { "op": "add", "path": "/a/c/0", "value": 0 },
        { "op": "replace", "path": "/a/b", "value": null },
        { "op": "remove", "path": "/k~1~0" }
    ]))
    .unwrap();
    apply_edits(&mut v, &edits).unwrap();
    assert_eq!(v, json!({ "a": { "b": null, "c": [0, 1, 2, 3], "d": "new" } }));
}

#[test]
fn an_edit_that_misses_is_an_error_naming_it() {
    for (edit, path) in [
        (json!({ "op": "replace", "path": "/nope", "value": 1 }), "/nope"),
        (json!({ "op": "remove", "path": "/a/9" }), "/a/9"),
        (json!({ "op": "add", "path": "/x/y", "value": 1 }), "/x/y"),
        (json!({ "op": "add", "path": "/a/5", "value": 1 }), "/a/5"),
        (json!({ "op": "add", "path": "", "value": 1 }), "edits[0]"),
        (json!({ "op": "add", "path": "/a/-" }), "value"),
    ] {
        let mut v = json!({ "a": [1] });
        let edits: Vec<Edit> = serde_json::from_value(json!([edit])).unwrap();
        assert_names(&apply_edits(&mut v, &edits).unwrap_err(), path);
    }
}

#[test]
fn it_rejects_an_unknown_field() {
    let mut v = minimal();
    v["bogus"] = json!(1);
    assert_names(&rejected(v), "bogus");
    let mut v = minimal();
    v["expect"]["rows"] = json!([]);
    assert_names(&rejected(v), "rows");
}

#[test]
fn it_rejects_another_format_or_an_id_that_is_not_the_stem() {
    let mut v = minimal();
    v["format"] = json!(2);
    assert_names(&rejected(v), "format");
    let dir = root();
    assert_names(&Case::load(&write(&dir, "other", &minimal())).unwrap_err(), "id");
}

#[test]
fn it_rejects_a_case_that_expects_nothing() {
    let mut v = minimal();
    v["expect"] = json!({});
    assert_names(&rejected(v), "expect");
}

#[test]
fn it_rejects_a_status_that_publishes_no_snapshot() {
    for status in
        [json!({ "json": ["x"] }), json!({ "json": {} }), json!({ "json": { "BackendState": null } }), json!("x")]
    {
        let mut v = minimal();
        v["status"] = status;
        assert_names(&rejected(v), "status");
    }
}

#[test]
fn it_waits_for_the_state_the_status_names() {
    let mut v = minimal();
    v["status"] = json!({ "json": { "BackendState": "NeedsLogin" } });
    let case = load(&v).unwrap();
    match &case.scenario().steps[1] {
        Step::Wait(Wait::Contract(w)) => {
            assert_eq!(json!(w), json!({ "wantRunning": true, "state": { "enum": "NeedsLogin" } }))
        }
        other => panic!("the snapshot wait is {other:?}"),
    }
}

#[test]
fn it_rejects_a_backend_state_the_contract_has_no_value_for() {
    let mut v = minimal();
    v["status"] = json!({ "json": { "BackendState": "Bogus" } });
    let error = rejected(v);
    assert_names(&error, "status");
    assert_names(&error, "Bogus");
}

#[test]
fn it_rejects_a_body_outside_the_fixture_root_or_missing() {
    for file in ["../captures/status.json", "/etc/passwd", "captures/none.json"] {
        let mut v = minimal();
        v["status"] = json!({ "file": file });
        assert_names(&rejected(v), "status");
    }
    let mut v = minimal();
    v["suggest"] = json!({ "file": "captures/none.json" });
    assert_names(&rejected(v), "suggest");
}

#[test]
fn it_rejects_a_suggestion_with_no_recommendation_expected() {
    let mut v = minimal();
    v["suggest"] = json!({ "json": { "ID": "nX1CNTRL" } });
    assert_names(&rejected(v.clone()), "recommendedExitNodeId");
    v["expect"]["contract"]["recommendedExitNodeId"] = json!("");
    assert_names(&rejected(v), "recommendedExitNodeId");
}

#[test]
fn it_rejects_a_row_that_reads_nothing_or_reads_by_number() {
    let mut v = full();
    v["expect"]["peers"] = json!([{}]);
    assert_names(&rejected(v), "peers[0]");
    let mut v = full();
    v["expect"]["exitNodes"] = json!([{ "#0": null }]);
    assert_names(&rejected(v), "exitNodes[0]");
    let mut v = full();
    v["expect"]["peers"][0]["online"] = json!({ "nope": 1 });
    assert_names(&rejected(v), "peers[0]");
}

#[test]
fn it_rejects_a_declaration_the_scenario_format_rejects() {
    let mut v = full();
    v["on"]["cpp-286"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.cpp-286");
    let mut v = full();
    v["on"]["cpp-286"]["failing"][0]["id"] = json!("peers[1]");
    assert_names(&rejected(v), "peers[1]");
    let mut v = minimal();
    v["requirements"] = json!(["PARSE-02"]);
    assert_names(&rejected(v), "requirements");
}

fn corpus_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../tests/fixtures/tailscale/corpus")
}

#[test]
fn every_committed_case_validates() {
    let Ok(entries) = std::fs::read_dir(corpus_dir()) else { return };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            Case::load(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        }
    }
}
