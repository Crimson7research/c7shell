//! What both self-test binaries share: the stub and self-test paths, and
//! how a check is reported.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Output;

use fake_tailscaled::scenario::Capability;
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::implementation::Implementation;
use tailscale_parity::runner::{self, Outcome, Report};

/// The QML-only stub C7 under `selftest/`.
pub fn stub_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("selftest/qml")
}

/// A file or directory under `selftest/`.
pub fn selftest(file: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("selftest").join(file)
}

pub const STUB_IMPLEMENTATIONS: &[(&str, &[Capability])] = &[("stub", &[])];

/// The stub as an implementation.
pub fn stub() -> Implementation {
    Implementation { name: "stub".into(), qml_dir: stub_dir(), capabilities: vec![] }
}

/// Runs one self-test scenario against the stub, with a small wait cap and
/// `extra` variables.
pub fn run_stub_with(file: &str, extra: &[(&str, &str)]) -> Report {
    let mut env = vec![("C7_HARNESS_MAX_ITERATIONS", "20000")];
    env.extend_from_slice(extra);
    runner::run_one(&stub(), STUB_IMPLEMENTATIONS, &selftest(file), &env)
}

/// Runs one self-test scenario against the stub, with a small wait cap.
pub fn run_stub(file: &str) -> Report {
    run_stub_with(file, &[])
}

/// Runs this binary again as `--child=<name>` in a fresh private root with
/// `env`, prints what it wrote and returns its output.
pub fn spawn_child(name: &str, env: &[(&str, &str)]) -> Output {
    let root = PrivateRoot::new();
    let arg = format!("--child={name}");
    let out = child::isolated(&[arg.as_str()], &root, env).output().unwrap();
    print!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    out
}

/// Asserts the runner's verdict on one self-test scenario.
pub fn verdict(
    failures: &mut Vec<String>,
    r: &Report,
    matches: bool,
    wants: &[&str],
    outcome: impl Fn(&Outcome) -> bool,
) {
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

/// An outcome that is an error containing `what`.
pub fn error(what: &str) -> impl Fn(&Outcome) -> bool + '_ {
    move |o: &Outcome| matches!(o, Outcome::Error(e) if e.contains(what))
}

/// Reports one check; returns whether it passed.
pub fn check(failures: &mut Vec<String>, ok: bool, what: &str) {
    println!("{} {what}", if ok { "ok  " } else { "FAIL" });
    if !ok {
        failures.push(what.to_string());
    }
}

/// Prints the verdict line for `name` and returns the exit code.
pub fn finish(name: &str, failures: &[String]) -> i32 {
    if failures.is_empty() {
        println!("{name}: PASS");
        0
    } else {
        println!("{name}: FAIL ({} failed)", failures.len());
        1
    }
}
