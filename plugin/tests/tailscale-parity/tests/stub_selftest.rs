//! The harness's own checks that need no reference build: the QML bridge,
//! the driver's start-up failures, the choice of implementation, and the
//! runner's verdicts, pinned on the QML-only stub C7 under `selftest/qml`.
//!
//! Each check that needs Qt runs in a respawned child with an isolated
//! environment, so QGuiApplication lives on that child's main thread.

mod support;

use serde_json::json;
use support::{check, error, finish, run_stub, selftest, spawn_child, stub, stub_dir, verdict, STUB_IMPLEMENTATIONS};
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::contract::Contract;
use tailscale_parity::implementation::Implementation;
use tailscale_parity::runner::{self, Outcome};
use tailscale_parity::{headless_app, load_driver};

/// Child: the driver over the stub C7 answers through the Probe.
fn child_probe() -> i32 {
    let app = headless_app();
    let loaded = match load_driver(&app, &stub_dir()) {
        Ok(l) => l,
        Err(e) => {
            println!("load failed: {e}");
            return 1;
        }
    };
    let c = Contract::new();
    let state = c.read("state");
    let call = c.call("setAcceptRoutes", &[json!(true)]);
    let after = c.read("writeError");
    let unknown = c.read("noSuchMember");
    drop(loaded);
    println!("PROBE {state:?} {call:?} {after:?} {unknown:?}");
    let ok = state == Ok(json!(0)) && call == Ok(json!(null)) && after == Ok(json!("set true")) && unknown.is_err();
    i32::from(!ok)
}

/// Child: a second engine over a C7 whose Tailscale is a type with no
/// instance reads "no object", not another object.
fn child_second_engine_no_object() -> i32 {
    let app = headless_app();
    let got = tailscale_parity::second_engine(&app, &selftest("qml-tailscale-type"));
    println!("SECOND-ENGINE {got:?}");
    i32::from(got != Ok("no object"))
}

/// Child: the driver over the C7 in `selftest/<dir>` must fail to load
/// with `want` in the reason, reported at once, not waited out.
fn child_load_fails(dir: &str, want: &str) -> i32 {
    let app = headless_app();
    match load_driver(&app, &selftest(dir)) {
        Ok(_) => {
            println!("LOAD-FAILS {dir} loaded");
            1
        }
        Err(e) => {
            println!("LOAD-FAILS {dir}: {e}");
            i32::from(!e.contains(want))
        }
    }
}

/// 1. The bridge, and a driver that cannot start.
fn the_bridge(failures: &mut Vec<String>) {
    // import C7Harness resolves, and a command emitted from Rust is answered
    // by the driver before the emit returns.
    let out = spawn_child("probe", &[("C7_QML_DIR", stub_dir().to_str().unwrap())]);
    check(failures, out.status.success(), "a Probe round trip returns what the driver read and called");
    // A driver that throws while it starts says why, at once.
    let out = spawn_child("no-tailscale", &[("C7_HARNESS_MAX_ITERATIONS", "20000")]);
    check(failures, out.status.success(), "a C7 without Tailscale fails to load with `Tailscale is not defined`");
    // A Tailscale that resolves to no backend object fails too, rather than
    // letting a scenario that reads only the fake pass with no backend.
    let out = spawn_child("tailscale-type", &[("C7_HARNESS_MAX_ITERATIONS", "20000")]);
    check(failures, out.status.success(), "a C7 whose Tailscale is a type fails to load: no backend object");
}

/// 2. The implementation is named, and its module directory must exist.
fn the_implementation(failures: &mut Vec<String>) {
    let missing = Implementation::from_vars(Some("cpp-286"), None).unwrap_err();
    check(failures, missing.contains("build-reference.sh"), &format!("C7_QML_DIR unset: {missing}"));
    let empty = PrivateRoot::new();
    let no_qmldir = Implementation::from_vars(Some("cpp-286"), Some(empty.path().to_str().unwrap())).unwrap_err();
    check(failures, no_qmldir.contains("build-reference.sh"), &format!("no C7/qmldir: {no_qmldir}"));
    let unknown = Implementation::from_vars(Some("qml6"), Some(stub_dir().to_str().unwrap())).unwrap_err();
    check(failures, unknown.contains("qml6"), &format!("unknown implementation: {unknown}"));
    let unset = Implementation::from_vars(None, Some(stub_dir().to_str().unwrap())).unwrap_err();
    check(failures, unset.contains("C7_IMPL"), &format!("C7_IMPL unset: {unset}"));
    let stub = Implementation::from_vars(Some("cpp-286"), Some(stub_dir().to_str().unwrap())).unwrap();
    check(failures, stub.name == "cpp-286" && stub.capabilities.is_empty(), "cpp-286 has no capabilities");
}

/// 3. A pass, and the child's environment: only the keep-list, the private
///    directories, dead buses, the platform, a fixed zone three hours
///    east of UTC and TS_SOCKET.
fn a_pass_and_its_environment(failures: &mut Vec<String>) {
    let pass = run_stub("scenarios/pass.json");
    verdict(failures, &pass, true, &["stub: pass, as declared"], |o| *o == Outcome::Pass);
    let env = pass.env.clone().unwrap_or_default();
    let names: Vec<&String> = env.keys().collect();
    let allowed = |n: &str| {
        child::kept(n)
            || child::PRIVATE.iter().any(|(v, _)| *v == n)
            || ["DBUS_SESSION_BUS_ADDRESS", "DBUS_SYSTEM_BUS_ADDRESS", "QT_QPA_PLATFORM", "TS_SOCKET", "TZ"]
                .contains(&n)
    };
    check(failures, names.iter().all(|n| allowed(n)), &format!("the child's environment is the allowlist: {names:?}"));
    // A local time read from a zone-less date is the host's unless the
    // child names its zone. Not UTC: there local time and UTC are the same
    // instant, which hides a date built as local time from UTC fields.
    let fixed = env.get("TZ").is_some_and(|v| v == "<+03>-3");
    check(failures, fixed, &format!("the child's TZ is UTC+3 with no DST: {:?}", env.get("TZ")));
    let under_root = |k: &str| env.get(k).is_some_and(|v| v.starts_with(pass.root.to_str().unwrap()));
    for k in ["TS_SOCKET", "HOME", "XDG_RUNTIME_DIR", "TMPDIR", "PATH"] {
        check(failures, under_root(k), &format!("the child's {k} is under its private root: {:?}", env.get(k)));
    }
}

/// 4. The verdicts on declared and undeclared results.
fn the_verdicts(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/declared-fail.json");
    verdict(failures, &r, true, &["fail as declared: error-text"], |o| matches!(o, Outcome::Fail(_)));
    let r = run_stub("scenarios/unexpected-pass.json");
    verdict(failures, &r, false, &["unexpected pass"], |o| *o == Outcome::Pass);
    let r = run_stub("scenarios/wrong-actual.json");
    verdict(failures, &r, false, &["\"set true\"", "\"set maybe\""], |o| matches!(o, Outcome::Fail(_)));
    let logged = "expect `error-text` failed: wanted {\"writeError\":\"set false\"}, actual \"set true\"";
    check(failures, r.log.contains(logged), &format!("the child logs what a failed expectation wanted: {logged}"));
    let r = run_stub("scenarios/cannot-run.json");
    verdict(failures, &r, true, &["cannot-run, as declared"], |o| *o == Outcome::CannotRun);
    check(failures, !r.started, "cannot-run: no child was started");
    let r = run_stub("scenarios/signal-count.json");
    verdict(failures, &r, true, &["fail as declared: fired-twice, never-fired"], |o| matches!(o, Outcome::Fail(_)));
}

/// 5. The errors, which never match a declaration.
fn the_errors(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/wait-never.json");
    verdict(failures, &r, false, &["wait never reached"], error("wait never reached: state"));
    let r = run_stub("scenarios/precondition.json");
    verdict(failures, &r, false, &["precondition"], error("precondition `setup`"));
    let r = run_stub("scenarios/needs-pass.json");
    verdict(failures, &r, false, &["on.stub"], error("on.stub"));
    let r = run_stub("scenarios/crash.json");
    verdict(failures, &r, false, &["no result line"], error("no result line"));
    let r = run_stub("scenarios/unknown-member.json");
    verdict(failures, &r, false, &["noSuchMember"], error("noSuchMember"));
    let r = run_stub("scenarios/connected-never.json");
    let never = "wait never reached: the fake has 1 connected clients";
    verdict(failures, &r, false, &[never], error(never));
}

/// 6. A fake op that reaches no client, or a hold never used, is an error.
fn the_fake_op_errors(failures: &mut Vec<String>) {
    for (file, op) in [
        ("push-reaches-none", "push_watch_line"),
        ("push-line-reaches-none", "push_line"),
        ("push-chunk-reaches-none", "push_chunk"),
        ("resume-reaches-none", "resume"),
        ("complete-reaches-none", "complete_held"),
    ] {
        let r = run_stub(&format!("scenarios/{file}.json"));
        let what = format!("steps[1]: {op} reached no client");
        verdict(failures, &r, false, &[&what], error(&what));
    }
    let r = run_stub("scenarios/hold-unused.json");
    let unused = "a hold was armed for \"/localapi/v0/status \" and never used";
    verdict(failures, &r, false, &[unused], error(unused));
}

/// 7. An empty scenario directory is a failure, never a pass, and a filter
///    id that names no scenario is an error naming it.
fn the_run_all_filters(failures: &mut Vec<String>) {
    let empty = PrivateRoot::new();
    let none = runner::run_all(&stub(), STUB_IMPLEMENTATIONS, empty.path(), 1, None);
    check(failures, none.as_ref().is_err_and(|e| e.contains("no scenarios found")), &format!("no scenarios: {none:?}"));
    let dir = selftest("scenarios");
    let filtered = runner::run_all(&stub(), STUB_IMPLEMENTATIONS, &dir, 1, Some("nothing-by-this-id"));
    check(
        failures,
        filtered.as_ref().is_err_and(|e| e.contains("no scenario has the id nothing-by-this-id")),
        &format!("a filter matching nothing is an error naming the id: {filtered:?}"),
    );
    let typo = runner::run_all(&stub(), STUB_IMPLEMENTATIONS, &dir, 1, Some("pass,typo"));
    check(
        failures,
        typo.as_ref().is_err_and(|e| e.contains("no scenario has the id typo")),
        &format!("a filter id naming no scenario: {typo:?}"),
    );
}

/// 8. A fault inside the fake comes before any other error or result.
fn the_conclusion(failures: &mut Vec<String>) {
    let faults = vec!["a write to client 1 timed out".to_string()];
    let concluded = [
        runner::conclude(Err("steps[3]: wait never reached: x".into()), None, &[], &faults, &[]),
        runner::conclude(Ok(()), None, &[], &faults, &[]),
    ];
    for o in &concluded {
        let ok = matches!(o, Outcome::Error(e) if e.starts_with("the fake failed: a write to client 1 timed out"));
        check(failures, ok, &format!("a fault in the fake is the error: {o:?}"));
    }
    let o = runner::conclude(Ok(()), None, &[], &[], &[]);
    check(failures, o == Outcome::Pass, &format!("no fault, nothing failing: {o:?}"));
}

/// 9. C7_REPEAT is a whole number of at least 1; anything else is refused.
fn the_repeat_count(failures: &mut Vec<String>) {
    for (value, want) in
        [(None, Some(1)), (Some("3"), Some(3)), (Some(" 2 "), None), (Some("0"), None), (Some("x"), None)]
    {
        let got = runner::parse_repeat(value);
        let ok = match (&got, want) {
            (Ok(n), Some(w)) => *n == w,
            (Err(e), None) => e.contains("C7_REPEAT"),
            _ => false,
        };
        check(failures, ok, &format!("C7_REPEAT={value:?} gives {got:?}"));
    }
}

/// 10. C7_HARNESS_MAX_ITERATIONS is a whole number of at least 1; a child
///     given anything else says so instead of waiting with the default cap.
fn the_wait_cap(failures: &mut Vec<String>) {
    for (value, want) in [
        (None, Some(tailscale_parity::MAX_ITERATIONS)),
        (Some("20000"), Some(20_000)),
        (Some("20k"), None),
        (Some("0"), None),
        (Some(""), None),
    ] {
        let got = tailscale_parity::parse_max_iterations(value);
        let ok = match (&got, want) {
            (Ok(n), Some(w)) => *n == w,
            (Err(e), None) => e.contains("C7_HARNESS_MAX_ITERATIONS"),
            _ => false,
        };
        check(failures, ok, &format!("C7_HARNESS_MAX_ITERATIONS={value:?} gives {got:?}"));
    }
    let bad = [("C7_HARNESS_MAX_ITERATIONS", "20k")];
    let r = runner::run_one(&stub(), STUB_IMPLEMENTATIONS, &selftest("scenarios/pass.json"), &bad);
    verdict(failures, &r, false, &["C7_HARNESS_MAX_ITERATIONS"], error("C7_HARNESS_MAX_ITERATIONS"));
}

/// 11. A string list is compared as an array, in a wait and an expect; a
///     failed comparison reports the array it read.
fn the_array_values(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/array-values.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(["a", ""]));
    verdict(failures, &r, true, &["fail as declared: shorter"], read);
}

/// 12. A model's rows: its count, a row's roles by name and by number, a
///     row off the end, its children and a wait on the count; a failed
///     model expectation reports what it read, and a role, row or member
///     that cannot be read is an error naming it.
fn the_model_reads(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/model-rows.json");
    let wants = ["fail as declared: stale-count, wrong-children, wrong-role, wrong-row"];
    let read = |o: &Outcome| {
        let actual = |id: &str| match o {
            Outcome::Fail(f) => f.iter().find(|f| f.id == id).map(|f| f.actual.clone()),
            _ => None,
        };
        actual("stale-count") == Some(json!(4))
            && actual("wrong-row") == Some(json!({ "hostName": "delta", "online": true }))
            && actual("wrong-role") == Some(json!("n4"))
    };
    verdict(failures, &r, true, &wants, read);
    for (file, what) in [
        ("model-unknown-role", "bogus is not a role of peers"),
        ("model-named-off-end", "peers has no row 99 to read hostName from"),
        ("model-not-a-model", "writeError is not a model"),
        ("model-wait-never", "wait never reached: peers has 9 rows (last read 3)"),
    ] {
        let r = run_stub(&format!("scenarios/{file}.json"));
        verdict(failures, &r, false, &[what], error(what));
    }
}

/// 13. Each model's own signals are counted from load as
///     `<member>.<signal>`, for every model member.
fn the_model_signals(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/model-signals.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(1));
    verdict(failures, &r, true, &["fail as declared: inserted-twice"], read);
}

/// 14. A mark records every counted signal, and a signal expectation
///     `since` it counts from there; a failed one reports that count.
fn the_signal_marks(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/signal-since.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(1));
    verdict(failures, &r, true, &["fail as declared: wrong-since"], read);
}

/// 15. Two model members are told apart as objects; the same member twice
///     is not distinct.
fn the_distinct_models(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/model-distinct.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(false));
    verdict(failures, &r, true, &["fail as declared: one-model"], read);
}

/// 16. A signal wait `since` a mark counts from there, so it waits past
///     what fired before the mark, and one that nothing after the mark
///     reaches is never reached.
fn the_signal_wait_marks(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/signal-wait-since.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(1));
    verdict(failures, &r, true, &["fail as declared: wrong-since"], read);
    let what = "wait never reached: peers.rowsInserted fired 1 times since after-one";
    let r = run_stub("scenarios/signal-wait-since-never.json");
    verdict(failures, &r, false, &[what], error(what));
}

/// 17. modelReset and layoutChanged are counted when they fire, not only
///     read as 0: the stub resets `peers` once and changes its layout once.
fn the_model_reset_and_layout(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/model-reset-layout.json");
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!(1));
    verdict(failures, &r, true, &["fail as declared: reset-twice"], read);
}

/// 18. A string matcher: `non_empty` and `contains` hold only for a string
///     that is non-empty or holds the text, in a wait, an expect, an array
///     and a model role; a failed one reports the value read.
fn the_string_matchers(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/string-matchers.json");
    let read = |o: &Outcome| {
        let actual = |id: &str| match o {
            Outcome::Fail(f) => f.iter().find(|f| f.id == id).map(|f| f.actual.clone()),
            _ => None,
        };
        actual("empty-is-not-non-empty") == Some(json!(""))
            && actual("does-not-contain") == Some(json!("set true"))
            && actual("not-a-string") == Some(json!(0))
    };
    let wants = ["fail as declared: does-not-contain, empty-is-not-non-empty, not-a-string"];
    verdict(failures, &r, true, &wants, read);
}

/// 19. A keep step stores a member's value; kept values differing pairwise
///     hold, a repeat is reported by label, and a kept object is the same
///     as its member and no other. A list or a date compares by value.
fn the_kept_values(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/kept-values.json");
    let read = |o: &Outcome| {
        let actual = |id: &str| match o {
            Outcome::Fail(f) => f.iter().find(|f| f.id == id).map(|f| f.actual.clone()),
            _ => None,
        };
        actual("repeat") == Some(json!({ "w1": "set true", "w2": "set false", "w3": "set false" }))
            && actual("not-same") == Some(json!(false))
            && actual("other-model") == Some(json!(false))
            && actual("equal-lists") == Some(json!({ "issues-1": [], "issues-2": [] }))
    };
    verdict(failures, &r, true, &["fail as declared: equal-lists, not-same, other-model, repeat"], read);
}

/// 20. Inside every firing after watch_handlers the driver reads the
///     watched members; a handlers expect checks every firing since the
///     watch or a mark, and reports the first firing that read otherwise,
///     or a signal that never fired.
fn the_handler_reads(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/handler-reads.json");
    let read = |o: &Outcome| {
        let actual = |id: &str| match o {
            Outcome::Fail(f) => f.iter().find(|f| f.id == id).map(|f| f.actual.clone()),
            _ => None,
        };
        actual("half-update") == Some(json!({ "signal": "acceptRoutesChanged", "values": { "writeError": "" } }))
            && actual("never-fired") == Some(json!({ "signal": "stateChanged", "fired": 0 }))
    };
    verdict(failures, &r, true, &["fail as declared: half-update, never-fired"], read);
}

/// 21. Assigning a read-only member from QML throws as read-only; a
///     writable one does not throw, and a value of the wrong type throws for
///     another reason. Each member reads as its type, and a wrong one
///     reports the types read.
fn the_members(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/members.json");
    let read = |o: &Outcome| {
        let actual = |id: &str| match o {
            Outcome::Fail(f) => f.iter().find(|f| f.id == id).map(|f| f.actual.clone()),
            _ => None,
        };
        actual("writable") == Some(json!({ "threw": false, "read_only": false }))
            && actual("wrong-type") == Some(json!({ "threw": true, "read_only": false }))
            && actual("wrong-member-type") == Some(json!({ "state": "number", "peers": "model" }))
            && actual("method-is-no-signal") == Some(json!({ "setAcceptRoutes": "function" }))
    };
    let wants = ["fail as declared: method-is-no-signal, writable, wrong-member-type, wrong-type"];
    verdict(failures, &r, true, &wants, read);
}

/// 22. The stub's Tailscale is one object per engine: a second component
///     in the driver's engine sees the same one, a second engine another,
///     and the driver still answers after that engine is gone. A Tailscale
///     the second engine reads as the driver's fails the check.
fn the_singleton(failures: &mut Vec<String>) {
    let r = run_stub("scenarios/singleton.json");
    verdict(failures, &r, true, &["stub: pass, as declared"], |o| *o == Outcome::Pass);
    // A second engine whose Tailscale reads as the driver's fails the check.
    let named = Implementation { qml_dir: selftest("qml-singleton-named"), ..stub() };
    let env = [("C7_HARNESS_MAX_ITERATIONS", "20000")];
    let r = runner::run_one(&named, STUB_IMPLEMENTATIONS, &selftest("scenarios/singleton-named.json"), &env);
    let same = json!({ "same_in_engine": true, "second_engine": "same" });
    let read = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == same);
    verdict(failures, &r, true, &["fail as declared: one-per-engine"], read);
    // A Tailscale that is a type with no instance is no object, not another.
    let out = spawn_child("second-engine-no-object", &[("C7_HARNESS_MAX_ITERATIONS", "20000")]);
    check(failures, out.status.success(), "a second engine whose Tailscale has no instance reads no object");
}

fn parent() -> i32 {
    let mut failures = Vec::new();
    the_bridge(&mut failures);
    the_implementation(&mut failures);
    a_pass_and_its_environment(&mut failures);
    the_verdicts(&mut failures);
    the_errors(&mut failures);
    the_fake_op_errors(&mut failures);
    the_run_all_filters(&mut failures);
    the_conclusion(&mut failures);
    the_repeat_count(&mut failures);
    the_wait_cap(&mut failures);
    the_array_values(&mut failures);
    the_model_reads(&mut failures);
    the_model_signals(&mut failures);
    the_signal_marks(&mut failures);
    the_distinct_models(&mut failures);
    the_signal_wait_marks(&mut failures);
    the_model_reset_and_layout(&mut failures);
    the_string_matchers(&mut failures);
    the_kept_values(&mut failures);
    the_handler_reads(&mut failures);
    the_members(&mut failures);
    the_singleton(&mut failures);
    finish("stub_selftest", &failures)
}

fn main() {
    let code = match child::child_arg().as_deref() {
        Some("probe") => child_probe(),
        Some("no-tailscale") => child_load_fails("qml-no-tailscale", "Tailscale is not defined"),
        Some("tailscale-type") => child_load_fails("qml-tailscale-type", "no backend object"),
        Some("second-engine-no-object") => child_second_engine_no_object(),
        Some("scenario") => runner::child_main(),
        Some(other) => panic!("unknown child {other}"),
        None => parent(),
    };
    std::process::exit(code);
}
