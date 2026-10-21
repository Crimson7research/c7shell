//! Bring-up checks of the harness itself: the QML bridge, the choice of
//! implementation, and #286's C7 read from Rust.
//!
//! Each check that needs Qt runs in a respawned child with an isolated
//! environment, so QGuiApplication lives on that child's main thread and a
//! singleton is constructed fresh with the TS_SOCKET the test chose.

use std::path::{Path, PathBuf};

use serde_json::json;
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::contract::Contract;
use tailscale_parity::implementation::Implementation;
use tailscale_parity::{headless_app, load_driver};

fn stub_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("selftest/qml")
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
    let out = child::isolated(&["--child=probe"], &root, &[("C7_QML_DIR", stub_dir().to_str().unwrap())]).output().unwrap();
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
        }
    }

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
        Some(other) => panic!("unknown child {other}"),
        None => parent(),
    };
    std::process::exit(code);
}
