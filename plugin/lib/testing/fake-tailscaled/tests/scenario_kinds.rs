//! The scenario kinds #308 adds: what the format accepts, what it rejects
//! and why.

mod support;

use serde_json::json;
use support::scenario::{assert_names, load, rejected, with_steps};
use support::TestDir;

#[test]
fn it_accepts_keep_steps_and_kept_expects() {
    let v = with_steps(json!([
        { "keep": { "label": "first", "member": "readError" } },
        { "keep": { "label": "second", "member": "readError" } },
        { "keep": { "label": "peers-before", "member": "peers" } },
        { "expect": { "id": "differ", "kept": { "distinct": ["first", "second"] } } },
        { "expect": { "id": "same-peers", "kept": { "same": "peers-before", "as": "peers" } } }
    ]));
    let dir = TestDir::new();
    let s = load(&dir, "full", &v).unwrap();
    assert_eq!(s.steps.len(), 27);
}

#[test]
fn it_rejects_a_keep_label_empty_twice_or_without_a_member() {
    let e = rejected(with_steps(json!([{ "keep": { "label": "", "member": "readError" } }])));
    assert_names(&e, "steps[22].keep: empty label");
    let e = rejected(with_steps(json!([
        { "keep": { "label": "a", "member": "readError" } },
        { "keep": { "label": "a", "member": "writeError" } }
    ])));
    assert_names(&e, "steps[23].keep: `a` twice");
    let e = rejected(with_steps(json!([{ "keep": { "label": "a", "member": "" } }])));
    assert_names(&e, "steps[22].keep: empty member");
}

#[test]
fn it_rejects_a_kept_expect_naming_no_earlier_keep() {
    let e = rejected(with_steps(json!([
        { "expect": { "id": "early", "kept": { "same": "later", "as": "peers" } } },
        { "keep": { "label": "later", "member": "peers" } }
    ])));
    assert_names(&e, "steps[22].expect `early`");
    assert_names(&e, "no earlier keep `later`");
    let e = rejected(with_steps(json!([
        { "keep": { "label": "a", "member": "readError" } },
        { "expect": { "id": "early", "kept": { "distinct": ["a", "b"] } } }
    ])));
    assert_names(&e, "no earlier keep `b`");
}

#[test]
fn it_rejects_a_kept_expect_with_too_few_labels_a_repeat_or_two_kinds() {
    let keep = json!({ "keep": { "label": "a", "member": "readError" } });
    let kept = |check: serde_json::Value| with_steps(json!([keep, { "expect": { "id": "k", "kept": check } }]));
    let e = rejected(kept(json!({ "distinct": ["a"] })));
    assert_names(&e, "steps[23].expect `k`: kept: distinct names at least two labels");
    let e = rejected(kept(json!({ "distinct": ["a", "a"] })));
    assert_names(&e, "kept: distinct names `a` twice");
    let e = rejected(kept(json!({ "same": "a" })));
    assert_names(&e, "kept: give exactly one of distinct and same with as");
    let e = rejected(kept(json!({ "distinct": ["a", "a"], "same": "a", "as": "peers" })));
    assert_names(&e, "kept: give exactly one of distinct and same with as");
    let e = rejected(with_steps(json!([
        keep,
        { "expect": { "id": "k", "kept": { "same": "a", "as": "peers" }, "signal": { "name": "stateChanged", "count": 0 } } }
    ])));
    assert_names(&e, "exactly one of contract, signal, request, request_parts, requests, model and kept");
}
