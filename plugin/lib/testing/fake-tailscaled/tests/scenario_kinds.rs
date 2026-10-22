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
    assert_names(&e, "exactly one of contract, signal, request, request_parts, requests, model, kept and handlers");
}

#[test]
fn it_accepts_watched_handlers_and_handler_expects() {
    let v = with_steps(json!([
        { "watch_handlers": ["state", "readError", "peers"] },
        { "mark": "before" },
        { "expect": { "id": "inside", "handlers": { "signals": ["stateChanged", "readErrorChanged"], "since": "before",
                      "values": { "state": { "enum": "NoState" }, "readError": { "non_empty": true }, "peers": { "rows": 20 } } } } },
        { "expect": { "id": "from-the-watch", "handlers": { "signals": ["stateChanged"], "values": { "state": 5 } } } }
    ]));
    let dir = TestDir::new();
    let s = load(&dir, "full", &v).unwrap();
    assert_eq!(s.steps.len(), 26);
}

#[test]
fn it_rejects_a_handler_watch_that_is_empty_repeats_a_member_or_comes_twice() {
    let e = rejected(with_steps(json!([{ "watch_handlers": [] }])));
    assert_names(&e, "steps[22].watch_handlers: empty");
    let e = rejected(with_steps(json!([{ "watch_handlers": ["state", "state"] }])));
    assert_names(&e, "steps[22].watch_handlers: `state` twice");
    let e = rejected(with_steps(json!([{ "watch_handlers": ["state"] }, { "watch_handlers": ["readError"] }])));
    assert_names(&e, "steps[23].watch_handlers: a scenario watches handlers once");
}

#[test]
fn it_rejects_a_handler_expect_without_a_watch_of_its_members() {
    let inside = |values: serde_json::Value| json!({ "expect": { "id": "inside", "handlers": { "signals": ["stateChanged"], "values": values } } });
    let e = rejected(with_steps(json!([inside(json!({ "state": 0 })), { "watch_handlers": ["state"] }])));
    assert_names(&e, "steps[22].expect `inside`: handlers: no earlier watch_handlers");
    let e = rejected(with_steps(json!([{ "watch_handlers": ["state"] }, inside(json!({ "readError": "" }))])));
    assert_names(&e, "steps[23].expect `inside`: handlers: `readError` is not watched");
}

#[test]
fn it_rejects_a_handler_expect_with_no_signals_no_values_or_an_unknown_mark() {
    let watch = json!({ "watch_handlers": ["state"] });
    let inside =
        |handlers: serde_json::Value| with_steps(json!([watch, { "expect": { "id": "h", "handlers": handlers } }]));
    let e = rejected(inside(json!({ "signals": [], "values": { "state": 0 } })));
    assert_names(&e, "steps[23].expect `h`: handlers: signals: empty");
    let e = rejected(inside(json!({ "signals": ["stateChanged"], "values": {} })));
    assert_names(&e, "handlers: values: empty");
    let e = rejected(inside(json!({ "signals": ["stateChanged"], "values": { "state": { "regex": "x" } } })));
    assert_names(&e, "handlers: values.state");
    let e = rejected(inside(json!({ "signals": ["stateChanged"], "since": "later", "values": { "state": 0 } })));
    assert_names(&e, "no earlier mark `later`");
}

#[test]
fn it_accepts_a_model_as_its_row_count_and_rejects_another_count() {
    let mut v = support::scenario::full();
    v["steps"][17]["expect"]["contract"] = json!({ "peers": { "rows": 2 } });
    let dir = TestDir::new();
    load(&dir, "full", &v).unwrap();
    let mut v = support::scenario::full();
    v["steps"][17]["expect"]["contract"] = json!({ "peers": { "rows": -1 } });
    assert_names(&rejected(v), "rows");
}
