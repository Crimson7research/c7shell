//! The scenario file format: what it accepts, what it rejects and why, and
//! that every committed scenario validates.

mod support;

use std::path::{Path, PathBuf};

use fake_tailscaled::scenario::{Capability, Scenario};
use serde_json::{json, Value};
use support::scenario::{assert_names, full, load, rejected, timed, with_steps};
use support::TestDir;

#[test]
fn it_accepts_every_step_and_expect_kind() {
    let dir = TestDir::new();
    let s = load(&dir, "full", &full()).unwrap();
    assert_eq!(s.id, "full");
    assert_eq!(s.steps.len(), 22);
    assert!(s.derived_needs().is_empty());
    let t = load(&dir, "timed", &timed()).unwrap();
    let mut needs = t.derived_needs().into_iter().collect::<Vec<_>>();
    needs.sort();
    let mut want = vec![Capability::Clock, Capability::ReadBarrier, Capability::IdleBarrier, Capability::RetryHook];
    want.sort();
    assert_eq!(needs, want);
}

#[test]
fn it_builds_the_fake_script_from_the_rules() {
    let dir = TestDir::new();
    let s = load(&dir, "full", &full()).unwrap();
    assert_eq!(s.fake.rules.len(), 3);
    s.fake.validate().unwrap();
}

#[test]
fn it_rejects_an_unknown_field() {
    let mut v = full();
    v["bogus"] = json!(1);
    assert_names(&rejected(v), "bogus");
    let mut v = full();
    v["steps"][1]["call"]["extra"] = json!(1);
    assert_names(&rejected(v), "extra");
}

#[test]
fn it_rejects_another_format() {
    let mut v = full();
    v["format"] = json!(2);
    assert_names(&rejected(v), "format");
}

#[test]
fn it_rejects_an_id_that_is_not_the_file_stem() {
    let dir = TestDir::new();
    assert_names(&load(&dir, "other-name", &full()).unwrap_err(), "id");
}

#[test]
fn it_rejects_empty_or_malformed_requirements() {
    let mut v = full();
    v["requirements"] = json!([]);
    assert_names(&rejected(v), "requirements");
    let mut v = full();
    v["requirements"] = json!(["HTTP-09"]);
    assert_names(&rejected(v), "requirements");
}

#[test]
fn it_rejects_no_clauses() {
    let mut v = full();
    v["clauses"] = json!([]);
    assert_names(&rejected(v), "clauses");
}

#[test]
fn it_rejects_a_clock_advance_the_needs_hide() {
    let mut v = timed();
    v["needs"] = json!([]);
    assert_names(&rejected(v), "needs");
    let mut v = timed();
    v["needs"] = json!(["clock", "read-barrier", "idle-barrier", "retry-hook", "clock-hook"]);
    assert_names(&rejected(v), "needs");
}

#[test]
fn it_rejects_harness_on_cpp_with_needs() {
    let mut v = timed();
    v["evidence"] = json!("harness-on-cpp");
    assert_names(&rejected(v), "evidence");
}

#[test]
fn it_rejects_a_fix_that_passes_on_cpp_286() {
    let mut v = full();
    v["on"]["cpp-286"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.cpp-286");
}

#[test]
fn it_rejects_a_parity_scenario_that_fails() {
    let mut v = full();
    v["tag"] = json!("parity");
    assert_names(&rejected(v), "on.cpp-286");
}

#[test]
fn it_rejects_cannot_run_where_the_implementation_has_the_needs() {
    let mut v = full();
    v["on"]["cpp-286"] = json!({ "result": "cannot-run", "reason": "?" });
    assert_names(&rejected(v), "on.cpp-286");
}

#[test]
fn it_rejects_running_without_the_needs() {
    let mut v = timed();
    v["on"]["rust"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.rust");
}

#[test]
fn it_rejects_failing_ids_that_are_unknown_or_preconditions() {
    let mut v = full();
    v["on"]["cpp-286"]["failing"] = json!([{ "id": "nope", "actual": 1 }]);
    assert_names(&rejected(v), "failing");
    let mut v = full();
    v["on"]["cpp-286"]["failing"] = json!([{ "id": "patch-sent", "actual": 0 }]);
    assert_names(&rejected(v), "failing");
    let mut v = full();
    v["on"]["cpp-286"]["failing"] = json!([]);
    assert_names(&rejected(v), "failing");
    let mut v = full();
    v["on"]["cpp-286"].as_object_mut().unwrap().remove("reason");
    assert_names(&rejected(v), "reason");
}

#[test]
fn it_rejects_a_missing_or_unknown_implementation() {
    let mut v = full();
    v["on"].as_object_mut().unwrap().remove("rust");
    assert_names(&rejected(v), "on.rust");
    let mut v = full();
    v["on"]["qml6"] = json!({ "result": "pass" });
    assert_names(&rejected(v), "on.qml6");
}

#[test]
fn it_rejects_duplicate_expect_ids() {
    let mut v = full();
    v["steps"][18]["expect"]["id"] = json!("error");
    assert_names(&rejected(v), "expect");
}

#[test]
fn it_rejects_split_offsets_out_of_order() {
    let mut v = full();
    v["fake"]["rules"][1]["reply"]["split"] = json!([{ "at": 10, "await": "a" }, { "at": 5, "await": "b" }]);
    assert_names(&rejected(v), "split");
}

#[test]
fn it_rejects_an_expect_with_no_or_two_kinds() {
    let mut v = full();
    v["steps"][17]["expect"] = json!({ "id": "e" });
    assert_names(&rejected(v), "expect");
    let mut v = full();
    v["steps"][17]["expect"]["signal"] = json!({ "name": "stateChanged", "count": 0 });
    assert_names(&rejected(v), "expect");
}

#[test]
fn it_rejects_a_value_it_cannot_compare() {
    let mut v = full();
    v["steps"][17]["expect"]["contract"] = json!({ "writeError": { "regex": "x" } });
    assert_names(&rejected(v), "writeError");
}

#[test]
fn it_rejects_a_fake_wait_with_no_or_two_kinds() {
    let mut v = full();
    v["steps"][4]["wait"]["fake"] = json!({});
    assert_names(&rejected(v), "wait.fake");
    let mut v = full();
    v["steps"][4]["wait"]["fake"] = json!({ "connected": 1, "held": 1 });
    assert_names(&rejected(v), "wait.fake");
}

#[test]
fn it_rejects_steps_that_do_not_start_with_start() {
    let mut v = full();
    v["steps"].as_array_mut().unwrap().remove(0);
    assert_names(&rejected(v), "start");
    let mut v = full();
    v["steps"].as_array_mut().unwrap().push(json!({ "start": {} }));
    assert_names(&rejected(v), "start");
}

#[test]
fn it_validates_against_another_implementation_set() {
    let mut v = full();
    v["on"] = json!({ "stub": { "result": "pass" } });
    let dir = TestDir::new();
    let path = dir.join("full.json");
    std::fs::write(&path, v.to_string()).unwrap();
    let stub = [("stub", &[][..])];
    Scenario::load_for(&path, &stub).unwrap();
    assert_names(&Scenario::load(&path).unwrap_err(), "on.cpp-286");
}

/// The repository's `tests/fixtures/tailscale/scenarios/`.
fn scenario_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../tests/fixtures/tailscale/scenarios")
}

#[test]
fn every_committed_scenario_validates() {
    let Ok(entries) = std::fs::read_dir(scenario_dir()) else { return };
    for entry in entries {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            Scenario::load(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        }
    }
}

#[test]
fn it_rejects_a_push_or_completion_over_the_write_limit() {
    let big = "x".repeat(fake_tailscaled::MAX_WRITE + 1);
    for op in [
        json!({ "push_line": big }),
        json!({ "push_chunk": big }),
        json!({ "push_watch_line": big }),
        json!({ "complete_held": { "body": big } }),
    ] {
        let name = op.as_object().unwrap().keys().next().unwrap().clone();
        let mut v = full();
        v["steps"][7] = json!({ "fake": op });
        let e = rejected(v);
        assert_names(&e, &format!("steps[7].fake.{name}"));
        assert_names(&e, "write limit");
    }
}

#[test]
fn it_rejects_a_rust_declaration_of_fail() {
    let mut v = full();
    v["on"]["rust"] =
        json!({ "result": "fail", "failing": [{ "id": "error", "actual": "y" }], "reason": "a regression" });
    let e = rejected(v);
    assert_names(&e, "on.rust");
    assert_names(&e, "rewrite");
}

#[test]
fn it_rejects_a_failing_id_named_twice() {
    let mut v = full();
    v["on"]["cpp-286"]["failing"] = json!([{ "id": "error", "actual": "y" }, { "id": "error", "actual": "z" }]);
    let e = rejected(v);
    assert_names(&e, "on.cpp-286: failing");
    assert_names(&e, "named twice");
}

#[test]
fn it_rejects_failing_on_a_pass_or_a_cannot_run() {
    let mut v = full();
    v["on"]["rust"] = json!({ "result": "pass", "failing": [{ "id": "error", "actual": "y" }] });
    assert_names(&rejected(v), "on.rust: failing");
    let mut v = timed();
    v["on"]["rust"] = json!({ "result": "cannot-run", "failing": [{ "id": "state", "actual": 1 }], "reason": "later" });
    assert_names(&rejected(v), "on.rust: failing");
}

#[test]
fn it_rejects_a_requirement_number_that_is_not_two_digits() {
    for bad in ["R-HTTP-1", "R-HTTP-100", "R-HTTP-0a", "R--01", "R-http-01"] {
        let mut v = full();
        v["requirements"] = json!([bad]);
        let e = rejected(v);
        assert_names(&e, "requirements");
        assert_names(&e, bad);
    }
}

#[test]
fn it_rejects_a_count_without_recorded() {
    let mut v = full();
    v["steps"][4]["wait"]["fake"] = json!({ "connected": 1, "count": 1 });
    let e = rejected(v);
    assert_names(&e, "steps[4].wait.fake");
    assert_names(&e, "count goes with recorded");
}

#[test]
fn it_rejects_an_empty_contract_map_in_a_wait_or_an_expect() {
    let mut v = full();
    v["steps"][2]["wait"]["contract"] = json!({});
    let e = rejected(v);
    assert_names(&e, "steps[2].wait.contract");
    assert_names(&e, "empty");
    let mut v = full();
    v["steps"][17]["expect"]["contract"] = json!({});
    let e = rejected(v);
    assert_names(&e, "steps[17].expect `error`: contract");
    assert_names(&e, "empty");
}

#[test]
fn it_accepts_an_array_value_in_a_wait_and_an_expect() {
    let mut v = full();
    v["steps"][2]["wait"]["contract"] = json!({ "issues": ["a", ""] });
    v["steps"][17]["expect"]["contract"] = json!({ "issues": [], "tags": [["nested"], { "enum": "Running" }] });
    let dir = TestDir::new();
    load(&dir, "full", &v).unwrap();
}

#[test]
fn it_rejects_an_array_holding_a_value_it_cannot_compare() {
    let mut v = full();
    v["steps"][17]["expect"]["contract"] = json!({ "issues": ["a", { "regex": "x" }] });
    let e = rejected(v);
    assert_names(&e, "steps[17].expect `error`: contract.issues");
    assert_names(&e, "regex");
    let mut v = full();
    v["steps"][2]["wait"]["contract"] = json!({ "issues": [{ "regex": "x" }] });
    assert_names(&rejected(v), "steps[2].wait.contract.issues");
}

/// `full()` with one model expectation `query` appended, as `steps[22]`.
fn with_model_expect(query: Value) -> Value {
    with_steps(json!([{ "expect": { "id": "model", "model": query } }]))
}

#[test]
fn it_accepts_every_model_query_in_an_expect_and_a_wait() {
    let v = with_steps(json!([
        { "wait": { "model": { "name": "peers", "count": 3 } } },
        { "wait": { "model": { "name": "peers", "row": 0, "values": { "hostName": "gamma" } } } },
        { "expect": { "id": "rows", "model": { "name": "peers", "count": 3 } } },
        { "expect": { "id": "child-rows", "model": { "name": "peers", "row": 0, "count": 0 } } },
        { "expect": { "id": "gamma", "model": { "name": "peers", "row": 0,
                                               "values": { "hostName": "gamma", "group": 1, "online": true } } } },
        { "expect": { "id": "off-end", "model": { "name": "peers", "row": 99, "values": { "#0": { "undefined": true } } } } },
        { "expect": { "id": "children", "model": { "name": "exitNodes", "row": 0, "has_children": false } } },
        { "expect": { "id": "root-children", "model": { "name": "exitNodes", "has_children": true } } },
        { "expect": { "id": "two-models", "model": { "name": "exitNodes", "distinct_from": "peers" } } }
    ]));
    let dir = TestDir::new();
    let s = load(&dir, "full", &v).unwrap();
    assert_eq!(s.steps.len(), 31);
}

#[test]
fn it_rejects_a_model_query_with_no_or_two_kinds() {
    let e = rejected(with_model_expect(json!({ "name": "peers" })));
    assert_names(&e, "steps[22].expect `model`: model");
    assert_names(&e, "exactly one of count, values, has_children and distinct_from");
    let e = rejected(with_model_expect(json!({ "name": "peers", "count": 1, "has_children": false })));
    assert_names(&e, "exactly one of count, values, has_children and distinct_from");
    let e = rejected(with_steps(json!([{ "wait": { "model": { "name": "peers" } } }])));
    assert_names(&e, "steps[22].wait.model");
}

#[test]
fn it_rejects_model_values_without_a_row_or_with_none() {
    let e = rejected(with_model_expect(json!({ "name": "peers", "values": { "hostName": "x" } })));
    assert_names(&e, "values needs a row");
    let e = rejected(with_model_expect(json!({ "name": "peers", "row": 0, "values": {} })));
    assert_names(&e, "values");
    assert_names(&e, "empty");
}

#[test]
fn it_rejects_a_role_it_cannot_name() {
    for bad in ["", "#", "#x", "#-1", "#1.5"] {
        let e = rejected(with_model_expect(json!({ "name": "peers", "row": 0, "values": { bad: 1 } })));
        assert_names(&e, "role");
        assert_names(&e, &format!("`{bad}`"));
    }
}

#[test]
fn it_rejects_a_model_value_it_cannot_compare_or_no_name() {
    let e =
        rejected(with_model_expect(json!({ "name": "peers", "row": 0, "values": { "hostName": { "regex": "x" } } })));
    assert_names(&e, "values.hostName");
    let e = rejected(with_model_expect(json!({ "name": "", "count": 0 })));
    assert_names(&e, "name");
    let e = rejected(with_model_expect(json!({ "name": "peers", "row": -1, "count": 0 })));
    assert_names(&e, "row");
}

/// Each error branch of `ModelQuery::validate` and `role()`, by its whole
/// message, so a branch that stops firing or says something else fails here.
#[test]
fn it_names_each_model_query_error_in_full() {
    let cases = [
        (
            json!({ "name": "peers", "row": -1, "count": 0 }),
            "row: -1 is negative; an invalid index reads the root, not a row",
        ),
        (json!({ "name": "exitNodes", "distinct_from": "" }), "distinct_from: empty; name the other member"),
        (json!({ "name": "", "count": 0 }), "name: empty; name the model member"),
        (json!({ "name": "peers", "row": 0, "values": {} }), "values: empty; name at least one role"),
        (
            json!({ "name": "peers", "row": 0, "values": { "#": 1 } }),
            "values.role `#`: # must be followed by a whole number",
        ),
        (
            json!({ "name": "peers", "row": 0, "values": { "#abc": 1 } }),
            "values.role `#abc`: # must be followed by a whole number",
        ),
        (
            json!({ "name": "peers", "row": 0, "values": { "#4294967296": 1 } }),
            "values.role `#4294967296`: the number is too large",
        ),
        (
            json!({ "name": "peers", "row": 0, "values": { "": 1 } }),
            "values.role ``: empty; give a role name or #<number>",
        ),
    ];
    for (query, message) in cases {
        let e = rejected(with_model_expect(query.clone()));
        assert!(e.ends_with(message), "{query}: wanted an error ending `{message}`, got: {e}");
    }
    // The largest role number still names a role.
    let dir = TestDir::new();
    load(&dir, "full", &with_model_expect(json!({ "name": "peers", "row": 0, "values": { "#4294967295": 1 } })))
        .unwrap();
}

#[test]
fn it_accepts_undefined_only_as_true() {
    let dir = TestDir::new();
    load(
        &dir,
        "full",
        &with_model_expect(json!({ "name": "peers", "row": 9, "values": { "#0": { "undefined": true } } })),
    )
    .unwrap();
    let mut v = full();
    v["steps"][17]["expect"]["contract"] = json!({ "writeError": { "undefined": true } });
    load(&dir, "full", &v).unwrap();
    let e =
        rejected(with_model_expect(json!({ "name": "peers", "row": 9, "values": { "#0": { "undefined": false } } })));
    assert_names(&e, "undefined");
}

#[test]
fn it_rejects_an_expect_with_a_model_and_another_kind() {
    let e = rejected(with_steps(json!([{ "expect": { "id": "two", "model": { "name": "peers", "count": 0 },
                                                       "signal": { "name": "stateChanged", "count": 0 } } }])));
    assert_names(&e, "exactly one of contract, signal, request, request_parts, requests, model and kept");
}

/// Writes `value` as `<root>/scenarios/<stem>.json`, so `{"file": ...}`
/// names a path under `<root>`, and loads it.
fn load_under(root: &TestDir, stem: &str, value: &Value) -> Result<Scenario, String> {
    std::fs::create_dir_all(root.join("scenarios")).unwrap();
    let path = root.join(format!("scenarios/{stem}.json"));
    std::fs::write(&path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    Scenario::load(&path)
}

/// `full()` with its status reply, its stream head and its completion
/// taking their bodies from `file`.
fn with_body_file(file: &str) -> Value {
    let mut v = full();
    v["fake"]["rules"][1]["reply"]["body"] = json!({ "file": file });
    v["fake"]["rules"][1]["reply"].as_object_mut().unwrap().remove("split");
    v["fake"]["rules"][0]["stream"]["body"] = json!({ "file": file });
    v["steps"][11]["fake"]["complete_held"]["body"] = json!({ "file": file });
    v
}

#[test]
fn it_reads_a_body_from_a_file_under_the_fixture_root() {
    let root = TestDir::new();
    std::fs::create_dir_all(root.join("captures")).unwrap();
    let capture = b"{\"BackendState\": \"Running\",\n \"Peer\": {}}\n";
    std::fs::write(root.join("captures/status.json"), capture).unwrap();
    let s = load_under(&root, "full", &with_body_file("captures/status.json")).unwrap();
    let reply = s.fake.rules[1].reply.as_ref().unwrap();
    assert_eq!(reply.body.0, capture, "the reply body is the file's bytes, unchanged");
    assert_eq!(s.fake.rules[0].stream.as_ref().unwrap().body.0, capture);
    match &s.steps[11] {
        fake_tailscaled::scenario::Step::Fake(fake_tailscaled::scenario::FakeOp::CompleteHeld(r)) => {
            assert_eq!(r.body.0, capture)
        }
        other => panic!("steps[11] is {other:?}"),
    }
}

#[test]
fn it_rejects_a_body_file_that_is_missing_or_outside_the_fixture_root() {
    let root = TestDir::new();
    let e = load_under(&root, "full", &with_body_file("captures/none.json")).unwrap_err();
    assert_names(&e, "fake.rules[0].stream.body.file");
    assert_names(&e, "captures/none.json");
    for bad in ["/etc/hostname", "../outside.json", "captures/../../outside.json", ""] {
        let e = load_under(&root, "full", &with_body_file(bad)).unwrap_err();
        assert_names(&e, "body.file");
        assert_names(&e, "relative");
    }
    let mut v = full();
    v["fake"]["rules"][1]["reply"]["body"] = json!({ "file": 7 });
    assert_names(&load_under(&root, "full", &v).unwrap_err(), "fake.rules[1].reply.body.file");
}

/// `full()` with one request_parts expectation `parts` appended, as
/// `steps[22]`.
fn with_request_parts(parts: Value) -> Value {
    with_steps(json!([{ "expect": { "id": "parts", "request_parts": parts } }]))
}

#[test]
fn it_accepts_request_parts_with_headers_and_a_json_body_or_without() {
    let dir = TestDir::new();
    let full_parts = json!({
        "match": { "method": "PATCH", "target": "/localapi/v0/prefs" },
        "starts_with": "PATCH /localapi/v0/prefs HTTP/1.1\r\n",
        "headers": [["Host", "local-tailscaled.sock"], ["Content-Length", "36"]],
        "body_json": { "RouteAll": true, "RouteAllSet": true }
    });
    load(&dir, "full", &with_request_parts(full_parts)).unwrap();
    let bare = json!({ "match": { "method": "GET", "path": "/localapi/v0/status" }, "starts_with": "GET " });
    load(&dir, "full", &with_request_parts(bare)).unwrap();
}

#[test]
fn it_rejects_request_parts_with_a_bad_match_an_empty_header_name_or_another_kind() {
    let e = rejected(with_request_parts(
        json!({ "match": { "method": "PATCH", "target": "/a", "path": "/a" }, "starts_with": "PATCH " }),
    ));
    assert_names(&e, "steps[22].expect `parts`: request_parts.match");
    let e = rejected(with_request_parts(
        json!({ "match": { "method": "PATCH", "target": "/a" }, "starts_with": "PATCH ", "headers": [["", "x"]] }),
    ));
    assert_names(&e, "request_parts.headers[0]");
    let e = rejected(with_request_parts(json!({ "match": { "method": "PATCH", "target": "/a" } })));
    assert_names(&e, "starts_with");
    let e = rejected(with_steps(
        json!([{ "expect": { "id": "two", "requests": { "match": { "method": "GET", "target": "/a" }, "count": 1 },
        "request_parts": { "match": { "method": "GET", "target": "/a" }, "starts_with": "GET " } } }]),
    ));
    assert_names(&e, "exactly one of contract, signal, request, request_parts, requests, model and kept");
}

#[test]
fn it_accepts_a_signal_count_since_an_earlier_mark() {
    let v = with_steps(json!([
        { "mark": "before-change" },
        { "fake": { "push_watch_line": "{\"State\":6}" } },
        { "expect": { "id": "moved", "signal": { "name": "peers.rowsMoved", "count": 1, "since": "before-change" } } }
    ]));
    let dir = TestDir::new();
    let s = load(&dir, "full", &v).unwrap();
    assert_eq!(s.steps.len(), 25);
}

#[test]
fn it_rejects_a_since_without_an_earlier_mark_and_a_mark_twice_or_empty() {
    let since = |label: &str| json!({ "expect": { "id": "since", "signal": { "name": "stateChanged", "count": 0, "since": label } } });
    let e = rejected(with_steps(json!([since("later"), { "mark": "later" }])));
    assert_names(&e, "steps[22].expect `since`");
    assert_names(&e, "no earlier mark `later`");
    let e = rejected(with_steps(json!([{ "mark": "a" }, { "mark": "a" }])));
    assert_names(&e, "steps[23].mark: `a` twice");
    let e = rejected(with_steps(json!([{ "mark": "" }])));
    assert_names(&e, "steps[22].mark: empty");
}

#[test]
fn it_rejects_distinct_from_with_a_row_or_no_name() {
    let e = rejected(with_model_expect(json!({ "name": "exitNodes", "row": 0, "distinct_from": "peers" })));
    assert_names(&e, "distinct_from takes no row");
    let e = rejected(with_model_expect(json!({ "name": "exitNodes", "distinct_from": "" })));
    assert_names(&e, "distinct_from");
    assert_names(&e, "empty");
}

#[test]
fn it_accepts_a_signal_wait_since_an_earlier_mark() {
    let v = with_steps(json!([
        { "mark": "before-push" },
        { "wait": { "signal": { "name": "stateChanged", "at_least": 1, "since": "before-push" } } }
    ]));
    let dir = TestDir::new();
    let s = load(&dir, "full", &v).unwrap();
    assert_eq!(s.steps.len(), 24);
}

#[test]
fn it_rejects_a_signal_wait_since_no_earlier_mark() {
    let wait = json!({ "wait": { "signal": { "name": "stateChanged", "at_least": 1, "since": "later" } } });
    let e = rejected(with_steps(json!([wait, { "mark": "later" }])));
    assert_names(&e, "steps[22].wait");
    assert_names(&e, "no earlier mark `later`");
}

#[test]
fn it_accepts_a_string_matcher_in_a_wait_and_an_expect() {
    let mut v = full();
    v["steps"][2]["wait"]["contract"] = json!({ "readError": { "non_empty": true } });
    v["steps"][17]["expect"]["contract"] =
        json!({ "writeError": { "contains": "403" }, "issues": [{ "contains": "DNS" }] });
    let dir = TestDir::new();
    load(&dir, "full", &v).unwrap();
}

#[test]
fn it_rejects_a_string_matcher_it_cannot_apply() {
    for (matcher, named) in [
        (json!({ "non_empty": false }), "non_empty"),
        (json!({ "contains": 403 }), "contains"),
        (json!({ "contains": "" }), "contains"),
    ] {
        let mut v = full();
        v["steps"][17]["expect"]["contract"] = json!({ "writeError": matcher });
        let e = rejected(v);
        assert_names(&e, "steps[17].expect `error`: contract.writeError");
        assert_names(&e, named);
    }
}
