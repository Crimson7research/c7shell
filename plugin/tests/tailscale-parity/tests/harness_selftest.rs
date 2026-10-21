//! Bring-up checks of the harness itself: the QML bridge, the choice of
//! implementation, and #286's C7 read from Rust.
//!
//! Each check that needs Qt runs in a respawned child with an isolated
//! environment, so QGuiApplication lives on that child's main thread and a
//! singleton is constructed fresh with the TS_SOCKET the test chose.

use std::path::{Path, PathBuf};

use fake_tailscaled::scenario::Capability;
use serde_json::json;
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::contract::Contract;
use tailscale_parity::implementation::Implementation;
use tailscale_parity::runner::{self, Outcome, Report};
use tailscale_parity::{headless_app, load_driver};

fn stub_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("selftest/qml")
}

fn selftest(file: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("selftest").join(file)
}

const STUB_IMPLEMENTATIONS: &[(&str, &[Capability])] = &[("stub", &[])];

/// cpp-286 alone, for a self-test declared to fail there that the rewrite
/// would fail too.
const CPP_ONLY: &[(&str, &[Capability])] = &[("cpp-286", &[])];

/// Runs one self-test scenario against the stub, with a small wait cap.
fn run_stub(file: &str) -> Report {
    let stub = Implementation { name: "stub".into(), qml_dir: stub_dir(), capabilities: vec![] };
    runner::run_one(&stub, STUB_IMPLEMENTATIONS, &selftest(file), &[("C7_HARNESS_MAX_ITERATIONS", "20000")])
}

/// Asserts the runner's verdict on one self-test scenario.
fn verdict(failures: &mut Vec<String>, r: &Report, matches: bool, wants: &[&str], outcome: impl Fn(&Outcome) -> bool) {
    let text = match &r.verdict {
        Ok(t) | Err(t) => t.clone(),
    };
    let ok = r.verdict.is_ok() == matches && wants.iter().all(|w| text.contains(w)) && outcome(&r.outcome);
    if !ok {
        print!("{}", r.log);
    }
    check(failures, ok, &format!("{}: {} ({:?})", r.id, text, r.outcome));
    check(failures, !r.root.exists(), &format!("{}: its private root {} is removed", r.id, r.root.display()));
}

/// The runner's verdicts on the stub, pinned.
fn runner_verdicts(failures: &mut Vec<String>) {
    let error = |what: &'static str| move |o: &Outcome| matches!(o, Outcome::Error(e) if e.contains(what));

    let pass = run_stub("scenarios/pass.json");
    verdict(failures, &pass, true, &["stub: pass, as declared"], |o| *o == Outcome::Pass);
    // The child's environment: only the keep-list, the private directories,
    // dead buses, the platform and TS_SOCKET.
    let env = pass.env.clone().unwrap_or_default();
    let names: Vec<&String> = env.keys().collect();
    let allowed = |n: &str| {
        child::kept(n)
            || child::PRIVATE.iter().any(|(v, _)| *v == n)
            || ["DBUS_SESSION_BUS_ADDRESS", "DBUS_SYSTEM_BUS_ADDRESS", "QT_QPA_PLATFORM", "TS_SOCKET"].contains(&n)
    };
    check(failures, names.iter().all(|n| allowed(n)), &format!("the child's environment is the allowlist: {names:?}"));
    let under_root = |k: &str| env.get(k).is_some_and(|v| v.starts_with(pass.root.to_str().unwrap()));
    for k in ["TS_SOCKET", "HOME", "XDG_RUNTIME_DIR", "TMPDIR", "PATH"] {
        check(failures, under_root(k), &format!("the child's {k} is under its private root: {:?}", env.get(k)));
    }

    let r = run_stub("scenarios/declared-fail.json");
    verdict(failures, &r, true, &["fail as declared: error-text"], |o| matches!(o, Outcome::Fail(_)));
    let r = run_stub("scenarios/unexpected-pass.json");
    verdict(failures, &r, false, &["unexpected pass"], |o| *o == Outcome::Pass);
    let r = run_stub("scenarios/wrong-actual.json");
    verdict(failures, &r, false, &["\"set true\"", "\"set maybe\""], |o| matches!(o, Outcome::Fail(_)));
    let logged = "expect `error-text` failed: wanted {\"writeError\":\"set false\"}, actual \"set true\"";
    check(failures, r.log.contains(logged), &format!("the child logs what a failed expectation wanted: {logged}"));
    let r = run_stub("scenarios/wait-never.json");
    verdict(failures, &r, false, &["wait never reached"], error("wait never reached: state"));
    let r = run_stub("scenarios/precondition.json");
    verdict(failures, &r, false, &["precondition"], error("precondition `setup`"));
    let r = run_stub("scenarios/cannot-run.json");
    verdict(failures, &r, true, &["cannot-run, as declared"], |o| *o == Outcome::CannotRun);
    check(failures, !r.started, "cannot-run: no child was started");
    let r = run_stub("scenarios/needs-pass.json");
    verdict(failures, &r, false, &["on.stub"], error("on.stub"));
    let r = run_stub("scenarios/crash.json");
    verdict(failures, &r, false, &["no result line"], error("no result line"));
    let r = run_stub("scenarios/unknown-member.json");
    verdict(failures, &r, false, &["noSuchMember"], error("noSuchMember"));
    let r = run_stub("scenarios/signal-count.json");
    verdict(failures, &r, true, &["fail as declared: fired-twice"], |o| matches!(o, Outcome::Fail(_)));
    // A fake op that reaches no client, or a hold never used, is an error.
    for (file, op) in [
        ("push-reaches-none", "push_watch_line"),
        ("push-line-reaches-none", "push_line"),
        ("push-chunk-reaches-none", "push_chunk"),
        ("resume-reaches-none", "resume"),
        ("complete-reaches-none", "complete_held"),
    ] {
        let r = run_stub(&format!("scenarios/{file}.json"));
        let what = format!("steps[1]: {op} reached no client");
        verdict(failures, &r, false, &[&what], |o| matches!(o, Outcome::Error(e) if e.contains(&what)));
    }
    let r = run_stub("scenarios/hold-unused.json");
    let unused = "a hold was armed for \"/localapi/v0/status \" and never used";
    verdict(failures, &r, false, &[unused], error(unused));
    let r = run_stub("scenarios/connected-never.json");
    let never = "wait never reached: the fake has 1 connected clients";
    verdict(failures, &r, false, &[never], error(never));

    // An empty scenario directory is a failure, never a pass.
    let empty = PrivateRoot::new();
    let stub = Implementation { name: "stub".into(), qml_dir: stub_dir(), capabilities: vec![] };
    let none = runner::run_all(&stub, STUB_IMPLEMENTATIONS, empty.path(), 1, None);
    check(failures, none.as_ref().is_err_and(|e| e.contains("no scenarios found")), &format!("no scenarios: {none:?}"));
    let filtered = runner::run_all(&stub, STUB_IMPLEMENTATIONS, &selftest("scenarios"), 1, Some("nothing-by-this-id"));
    check(
        failures,
        filtered.as_ref().is_err_and(|e| e.contains("no scenarios found")),
        "a filter matching nothing finds no scenarios",
    );
}

/// Reports one check; returns whether it passed.
fn check(failures: &mut Vec<String>, ok: bool, what: &str) {
    println!("{} {what}", if ok { "ok  " } else { "FAIL" });
    if !ok {
        failures.push(what.to_string());
    }
}

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

/// Child: #286's C7 with TS_SOCKET at an absent path, read from Rust.
fn child_contract() -> i32 {
    let imp = match Implementation::from_env() {
        Ok(i) => i,
        Err(e) => {
            println!("{e}");
            return 1;
        }
    };
    let socket = PathBuf::from(std::env::var_os("TS_SOCKET").expect("TS_SOCKET set by the parent"));
    let app = headless_app();
    let loaded = match load_driver(&app, &imp.qml_dir) {
        Ok(l) => l,
        Err(e) => {
            println!("load failed: {e}");
            return 1;
        }
    };
    let c = Contract::new();
    let mut failures = Vec::new();
    check(&mut failures, !socket.exists(), "TS_SOCKET names a path nothing is at");
    let state = c.read("state");
    let no_state = c.enum_value("NoState");
    check(&mut failures, state.is_ok() && state == no_state, &format!("state {state:?} equals NoState {no_state:?}"));
    let members = c.members().unwrap_or_default();
    check(&mut failures, members.iter().any(|m| m == "writeError"), "members() lists writeError");
    check(&mut failures, members.iter().any(|m| m == "setAcceptRoutes"), "members() lists setAcceptRoutes");
    let count = c.signal_count("writeErrorChanged");
    check(&mut failures, count == Ok(0), &format!("writeErrorChanged fired {count:?} times"));
    check(&mut failures, c.signal_count("noSuchSignal").is_err(), "an unknown signal is an error");
    drop(loaded);
    i32::from(!failures.is_empty())
}

fn parent() -> i32 {
    let mut failures = Vec::new();

    // 1. The bridge: import C7Harness resolves, and a command emitted from
    //    Rust is answered by the driver before the emit returns.
    let root = PrivateRoot::new();
    let out =
        child::isolated(&["--child=probe"], &root, &[("C7_QML_DIR", stub_dir().to_str().unwrap())]).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
    print!("{text}");
    check(&mut failures, out.status.success(), "a Probe round trip returns what the driver read and called");

    // 2. The implementation is named, and its module directory must exist.
    let missing = Implementation::from_vars(Some("cpp-286"), None).unwrap_err();
    check(&mut failures, missing.contains("build-reference.sh"), &format!("C7_QML_DIR unset: {missing}"));
    let empty = PrivateRoot::new();
    let no_qmldir = Implementation::from_vars(Some("cpp-286"), Some(empty.path().to_str().unwrap())).unwrap_err();
    check(&mut failures, no_qmldir.contains("build-reference.sh"), &format!("no C7/qmldir: {no_qmldir}"));
    let unknown = Implementation::from_vars(Some("qml6"), Some(stub_dir().to_str().unwrap())).unwrap_err();
    check(&mut failures, unknown.contains("qml6"), &format!("unknown implementation: {unknown}"));
    let unset = Implementation::from_vars(None, Some(stub_dir().to_str().unwrap())).unwrap_err();
    check(&mut failures, unset.contains("C7_IMPL"), &format!("C7_IMPL unset: {unset}"));
    let stub = Implementation::from_vars(Some("cpp-286"), Some(stub_dir().to_str().unwrap())).unwrap();
    check(&mut failures, stub.name == "cpp-286" && stub.capabilities.is_empty(), "cpp-286 has no capabilities");

    // 3. #286's C7, chosen by C7_IMPL and C7_QML_DIR, read from Rust.
    match Implementation::from_env() {
        Err(e) => check(&mut failures, false, &format!("#286's C7 is needed for this check: {e}")),
        Ok(imp) => {
            let root = PrivateRoot::new();
            let socket = root.path().join("run/tailscaled.sock");
            let out = child::isolated(
                &["--child=contract"],
                &root,
                &[
                    ("C7_IMPL", imp.name.as_str()),
                    ("C7_QML_DIR", imp.qml_dir.to_str().unwrap()),
                    ("TS_SOCKET", socket.to_str().unwrap()),
                ],
            )
            .output()
            .unwrap();
            print!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
            check(&mut failures, out.status.success(), "#286's C7 loads and Rust reads Tailscale through the driver");

            // 4. A request the script does not match is an error naming it.
            let r = runner::run_one(
                &imp,
                fake_tailscaled::scenario::IMPLEMENTATIONS,
                &selftest("scenarios-cpp/unmatched.json"),
                &[],
            );
            verdict(
                &mut failures,
                &r,
                false,
                &["unmatched", "GET /localapi/v0/prefs"],
                |o| matches!(o, Outcome::Error(e) if e.contains("GET /localapi/v0/prefs")),
            );

            // 5. A request expectation fails on other bytes with the bytes
            //    sent, and on a request never sent with null; a requests
            //    expectation fails on a wrong count with the count sent.
            let r = runner::run_one(&imp, CPP_ONLY, &selftest("scenarios-cpp/request-failures.json"), &[]);
            verdict(
                &mut failures,
                &r,
                true,
                &["fail as declared: never-sent, sent-twice, wrong-host"],
                |o| matches!(o, Outcome::Fail(f) if f.len() == 3),
            );
        }
    }

    // 6. The runner's verdicts, pinned on the stub.
    runner_verdicts(&mut failures);

    if failures.is_empty() {
        println!("harness_selftest: PASS");
        0
    } else {
        println!("harness_selftest: FAIL ({} failed)", failures.len());
        1
    }
}

fn main() {
    let code = match child::child_arg().as_deref() {
        Some("probe") => child_probe(),
        Some("contract") => child_contract(),
        Some("scenario") => runner::child_main(),
        Some(other) => panic!("unknown child {other}"),
        None => parent(),
    };
    std::process::exit(code);
}
