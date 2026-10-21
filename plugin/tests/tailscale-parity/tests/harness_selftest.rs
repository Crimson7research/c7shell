//! The harness's checks against #286's C7 at a38dbca, the reference build
//! `build-reference.sh` makes: the module read from Rust, and the runner's
//! verdicts on requests it really sends. `stub_selftest` holds the checks
//! that need no reference.
//!
//! Each check that needs Qt runs in a respawned child with an isolated
//! environment, so QGuiApplication lives on that child's main thread and a
//! singleton is constructed fresh with the TS_SOCKET the test chose.

mod support;

use std::path::PathBuf;

use fake_tailscaled::scenario::Capability;
use support::{check, finish, selftest, spawn_child, verdict};
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::contract::Contract;
use tailscale_parity::implementation::Implementation;
use tailscale_parity::runner::{self, Outcome};
use tailscale_parity::{headless_app, load_driver};

/// cpp-286 alone, for a self-test declared to fail there that the rewrite
/// would fail too.
const CPP_ONLY: &[(&str, &[Capability])] = &[("cpp-286", &[])];

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

/// 1. #286's C7, chosen by C7_IMPL and C7_QML_DIR, read from Rust.
fn the_module(failures: &mut Vec<String>, imp: &Implementation) {
    let root = PrivateRoot::new();
    let socket = root.path().join("run/tailscaled.sock");
    let env = [
        ("C7_IMPL", imp.name.as_str()),
        ("C7_QML_DIR", imp.qml_dir.to_str().unwrap()),
        ("TS_SOCKET", socket.to_str().unwrap()),
    ];
    let out = spawn_child("contract", &env);
    check(failures, out.status.success(), "#286's C7 loads and Rust reads Tailscale through the driver");
}

/// 2. A request the script does not match is an error naming it.
fn an_unmatched_request(failures: &mut Vec<String>, imp: &Implementation) {
    let path = selftest("scenarios-cpp/unmatched.json");
    let r = runner::run_one(imp, fake_tailscaled::scenario::IMPLEMENTATIONS, &path, &[]);
    let named = |o: &Outcome| matches!(o, Outcome::Error(e) if e.contains("GET /localapi/v0/prefs"));
    verdict(failures, &r, false, &["unmatched", "GET /localapi/v0/prefs"], named);
}

/// 3. A request expectation fails on other bytes with the bytes sent, and
///    on a request never sent with null; a requests expectation fails on a
///    wrong count with the count sent.
fn the_request_failures(failures: &mut Vec<String>, imp: &Implementation) {
    let r = runner::run_one(imp, CPP_ONLY, &selftest("scenarios-cpp/request-failures.json"), &[]);
    let wants = ["fail as declared: never-sent, sent-twice, wrong-host"];
    verdict(failures, &r, true, &wants, |o| matches!(o, Outcome::Fail(f) if f.len() == 3));
}

fn parent() -> i32 {
    let mut failures = Vec::new();
    match Implementation::from_env() {
        Err(e) => check(&mut failures, false, &format!("#286's C7 is needed for these checks: {e}")),
        Ok(imp) => {
            the_module(&mut failures, &imp);
            an_unmatched_request(&mut failures, &imp);
            the_request_failures(&mut failures, &imp);
        }
    }
    finish("harness_selftest", &failures)
}

fn main() {
    let code = match child::child_arg().as_deref() {
        Some("contract") => child_contract(),
        Some("scenario") => runner::child_main(),
        Some(other) => panic!("unknown child {other}"),
        None => parent(),
    };
    std::process::exit(code);
}
