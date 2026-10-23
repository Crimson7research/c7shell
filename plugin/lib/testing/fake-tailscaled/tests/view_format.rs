//! The view test header format: what it accepts, what it rejects and why.
//! The harness validates every committed header against its bodies.

mod support;

use fake_tailscaled::views::ViewTest;
use serde_json::{json, Value};
use support::scenario::assert_names;
use support::TestDir;

const BODIES: &[&str] = &["qml_01_no_slot", "ui_16_one_explanation"];

fn header() -> Value {
    json!({
        "format": 1,
        "id": "view",
        "requirements": ["R-QML-01"],
        "tag": "parity",
        "evidence": "harness-on-cpp",
        "clauses": ["the slot is not visible"],
        "deferred": ["nothing"],
        "body": "qml_01_no_slot",
        "on": { "cpp-286": { "result": "pass" }, "rust": { "result": "pass" } }
    })
}

fn fix() -> Value {
    let mut v = header();
    v["tag"] = json!("fix");
    v["body"] = json!("ui_16_one_explanation");
    v["on"]["cpp-286"] =
        json!({ "result": "fail", "failing": [{ "id": "one-text", "actual": 2 }], "reason": "two Texts" });
    v
}

fn load(dir: &TestDir, value: &Value) -> Result<ViewTest, String> {
    let stem = value["id"].as_str().unwrap_or("x");
    let path = dir.join(format!("{stem}.json"));
    std::fs::write(&path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    ViewTest::load(&path, BODIES)
}

fn rejected(value: Value) -> String {
    let dir = TestDir::new();
    match load(&dir, &value) {
        Ok(_) => panic!("accepted: {value}"),
        Err(e) => e,
    }
}

#[test]
fn it_accepts_a_parity_and_a_fix_header() {
    let dir = TestDir::new();
    let v = load(&dir, &header()).unwrap();
    assert_eq!((v.id.as_str(), v.body.as_str()), ("view", "qml_01_no_slot"));
    assert_eq!(v.requirements, ["R-QML-01"]);
    let f = load(&dir, &fix()).unwrap();
    assert_eq!(f.on["cpp-286"].failing.as_ref().unwrap()[0].id, "one-text");
}

#[test]
fn it_rejects_an_unknown_field_another_format_or_a_stem_mismatch() {
    let mut v = header();
    v["steps"] = json!([]);
    assert_names(&rejected(v), "steps");
    let mut v = header();
    v["format"] = json!(2);
    assert_names(&rejected(v), "format");
    let dir = TestDir::new();
    let path = dir.join("other.json");
    std::fs::write(&path, header().to_string()).unwrap();
    assert_names(&ViewTest::load(&path, BODIES).unwrap_err(), "id");
}

#[test]
fn it_rejects_empty_or_malformed_requirements_and_empty_clauses() {
    let mut v = header();
    v["requirements"] = json!([]);
    assert_names(&rejected(v), "requirements");
    let mut v = header();
    v["requirements"] = json!(["R-QML-1"]);
    assert_names(&rejected(v), "requirements");
    let mut v = header();
    v["clauses"] = json!([]);
    assert_names(&rejected(v), "clauses");
}

#[test]
fn it_rejects_a_body_no_function_has() {
    let mut v = header();
    v["body"] = json!("qml_99_nothing");
    let e = rejected(v);
    assert_names(&e, "body");
    assert_names(&e, "qml_99_nothing");
}

#[test]
fn it_rejects_evidence_other_than_harness_on_cpp() {
    let mut v = header();
    v["evidence"] = json!("cpp-suite");
    assert_names(&rejected(v), "evidence");
}

#[test]
fn it_applies_the_scenario_declaration_rules() {
    let mut v = header();
    v["on"].as_object_mut().unwrap().remove("rust");
    assert_names(&rejected(v), "on.rust: missing");
    let mut v = header();
    v["on"]["qml6"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.qml6");
    let mut v = header();
    v["on"]["cpp-286"] = json!({ "result": "fail", "failing": [{ "id": "x", "actual": 1 }], "reason": "r" });
    assert_names(&rejected(v), "on.cpp-286: a parity scenario cannot fail");
    let mut v = fix();
    v["on"]["cpp-286"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.cpp-286: a fix cannot pass");
    let mut v = fix();
    v["on"]["rust"] = v["on"]["cpp-286"].clone();
    assert_names(&rejected(v), "on.rust");
    let mut v = fix();
    v["on"]["cpp-286"]["reason"] = json!(" ");
    assert_names(&rejected(v), "on.cpp-286: reason");
    let mut v = fix();
    v["on"]["cpp-286"]["failing"] = json!([]);
    assert_names(&rejected(v), "on.cpp-286: failing");
    let mut v = fix();
    v["on"]["cpp-286"]["failing"] = json!([{ "id": "a", "actual": 1 }, { "id": "a", "actual": 2 }]);
    assert_names(&rejected(v), "named twice");
}

#[test]
fn it_rejects_cannot_run_for_a_view_test() {
    let mut v = header();
    v["on"]["rust"] = json!({ "result": "cannot-run", "reason": "later" });
    assert_names(&rejected(v), "on.rust: cannot-run");
}
