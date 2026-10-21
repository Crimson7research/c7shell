//! The scenario runner: runs one scenario's steps against a [`Contract`]
//! and a [`Fake`] in an isolated child, and compares the child's outcome
//! with the scenario's declaration for the implementation.
//!
//! An outcome matches its declaration when it is `Pass` for `pass`, `Fail`
//! with exactly the declared ids and actual values for `fail`, and
//! `CannotRun` for `cannot-run`. An `Error` (a wait never reached, an
//! unknown member, a failed precondition, an unmatched request, a crash or
//! a missing result line) never matches.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use fake_tailscaled::scenario::{Declaration, Failing, Implementation as Known, Scenario, Verdict};
use fake_tailscaled::{Bytes, Fake};
use serde_json::{json, Value};

use crate::child::{self, PrivateRoot};
use crate::contract::Contract;
use crate::headless_app;
use crate::implementation::Implementation;
use crate::steps::Run;

/// The line a child prints its outcome on.
pub const RESULT_PREFIX: &str = "C7-SCENARIO-RESULT ";

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Pass,
    /// The expectations that failed, with their actual values.
    Fail(Vec<Failing>),
    Error(String),
    CannotRun,
}

/// One scenario run and its verdict.
#[derive(Debug)]
pub struct Report {
    pub id: String,
    pub outcome: Outcome,
    /// Ok when the outcome matches the declaration, with a line saying so;
    /// Err with the mismatch.
    pub verdict: Result<String, String>,
    /// The child's private root, removed by the time the report exists.
    pub root: PathBuf,
    /// The child's stdout and stderr.
    pub log: String,
    /// The environment the child reported.
    pub env: Option<BTreeMap<String, String>>,
    /// Whether a child was started.
    pub started: bool,
}

/// Runs the scenario at `path` against `imp`, validated against
/// `implementations`, in an isolated child with `extra` variables.
pub fn run_one(imp: &Implementation, implementations: &[Known<'_>], path: &Path, extra: &[(&str, &str)]) -> Report {
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?").to_string();
    let root = PrivateRoot::new();
    let root_path = root.path().to_path_buf();
    let mut report = Report {
        id,
        outcome: Outcome::CannotRun,
        verdict: Ok(String::new()),
        root: root_path,
        log: String::new(),
        env: None,
        started: false,
    };
    let scenario = match Scenario::load_for(path, implementations) {
        Ok(s) => s,
        Err(e) => {
            report.outcome = Outcome::Error(e);
            report.verdict = Err(format!("{}: error: {}", imp.name, error_text(&report.outcome)));
            return report;
        }
    };
    let Some(declaration) = scenario.on.get(&imp.name) else {
        report.outcome = Outcome::Error(format!("on.{}: no declaration for this implementation", imp.name));
        report.verdict = Err(format!("{}: error: {}", imp.name, error_text(&report.outcome)));
        return report;
    };
    if scenario.needs.iter().all(|n| imp.capabilities.contains(n)) {
        report.started = true;
        (report.outcome, report.log, report.env) = run_child_of(imp, path, &root, extra);
    }
    report.verdict = compare(&imp.name, &report.outcome, declaration);
    drop(root);
    report
}

/// Runs the scenario at `path` in an isolated child under `root`, with
/// TS_SOCKET in it and `extra` variables; returns its outcome, its log and
/// the environment it reported.
fn run_child_of(
    imp: &Implementation,
    path: &Path,
    root: &PrivateRoot,
    extra: &[(&str, &str)],
) -> (Outcome, String, Option<BTreeMap<String, String>>) {
    let socket = root.path().join("run/tailscaled.sock");
    let args = [
        "--child=scenario".to_string(),
        format!("--scenario={}", path.display()),
        format!("--qml={}", imp.qml_dir.display()),
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let mut env = vec![("TS_SOCKET", socket.to_str().unwrap_or(""))];
    env.extend_from_slice(extra);
    let out = match child::isolated(&args, root, &env).output() {
        Ok(out) => out,
        Err(e) => return (Outcome::Error(format!("cannot start the child: {e}")), String::new(), None),
    };
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let log = stdout.clone() + &String::from_utf8_lossy(&out.stderr);
    let line = stdout.lines().rev().find_map(|l| l.strip_prefix(RESULT_PREFIX));
    match line.map(serde_json::from_str::<Value>) {
        Some(Ok(v)) => (outcome_from_json(&v), log, serde_json::from_value(v["env"].clone()).ok()),
        Some(Err(e)) => (Outcome::Error(format!("a malformed result line: {e}")), log, None),
        None => (Outcome::Error(format!("no result line (the child exited with {})", out.status)), log, None),
    }
}

/// Runs every scenario in `dir` (or those whose ids `filter` lists, comma
/// separated) `repeat` times, stopping at the first mismatch.
pub fn run_all(
    imp: &Implementation,
    implementations: &[Known<'_>],
    dir: &Path,
    repeat: u32,
    filter: Option<&str>,
) -> Result<String, String> {
    let wanted: Option<Vec<&str>> = filter.map(|f| f.split(',').map(str::trim).filter(|s| !s.is_empty()).collect());
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|entries| entries.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    paths.retain(|p| p.extension().is_some_and(|e| e == "json"));
    let stem = |p: &PathBuf| p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    if let Some(w) = &wanted {
        let stems: Vec<String> = paths.iter().map(stem).collect();
        let missing: Vec<&str> = w.iter().copied().filter(|id| !stems.iter().any(|s| s == id)).collect();
        if !missing.is_empty() {
            return Err(format!("no scenario has the id {} in {}", missing.join(", "), dir.display()));
        }
        paths.retain(|p| w.contains(&stem(p).as_str()));
    }
    paths.sort();
    if paths.is_empty() {
        return Err(format!("no scenarios found in {}", dir.display()));
    }
    for run in 1..=repeat {
        for path in &paths {
            let r = run_one(imp, implementations, path, &[]);
            match &r.verdict {
                Ok(line) => {
                    if run == 1 || repeat == 1 {
                        println!("ok {} ({line})", r.id);
                    }
                }
                Err(e) => {
                    print!("{}", r.log);
                    println!("FAIL {} ({e})", r.id);
                    return Err(format!("run {run} of {repeat}: {}: {e}", r.id));
                }
            }
        }
        if repeat > 1 {
            println!("run {run} of {repeat}: every scenario matched its declaration");
        }
    }
    Ok(format!("{} scenarios matched their declarations on {} in {repeat} runs", paths.len(), imp.name))
}

/// The repeat count `C7_REPEAT` gives: 1 when unset, else a whole number
/// of at least 1.
pub fn parse_repeat(value: Option<&str>) -> Result<u32, String> {
    match value.map(str::parse::<u32>) {
        None => Ok(1),
        Some(Ok(n)) if n >= 1 => Ok(n),
        _ => Err(format!("C7_REPEAT must be a whole number of at least 1, not {:?}", value.unwrap_or(""))),
    }
}

fn error_text(o: &Outcome) -> String {
    match o {
        Outcome::Error(e) => e.clone(),
        other => format!("{other:?}"),
    }
}

/// Whether `outcome` matches `declaration` on `imp`.
pub fn compare(imp: &str, outcome: &Outcome, declaration: &Declaration) -> Result<String, String> {
    let declared: Vec<Failing> = sorted(declaration.failing.clone().unwrap_or_default());
    match (outcome, declaration.result) {
        (Outcome::Error(e), _) => Err(format!("{imp}: error: {e}")),
        (Outcome::Pass, Verdict::Pass) => Ok(format!("{imp}: pass, as declared")),
        (Outcome::CannotRun, Verdict::CannotRun) => Ok(format!("{imp}: cannot-run, as declared")),
        (Outcome::Fail(f), Verdict::Fail) if sorted(f.clone()) == declared => {
            let ids: Vec<&str> = declared.iter().map(|f| f.id.as_str()).collect();
            Ok(format!("{imp}: fail as declared: {}", ids.join(", ")))
        }
        (Outcome::Fail(f), Verdict::Fail) => {
            Err(format!("{imp}: declared failing {}, but got failing {}", json!(declared), json!(sorted(f.clone()))))
        }
        (Outcome::Pass, Verdict::Fail) => Err(format!("{imp}: unexpected pass; declared failing {}", json!(declared))),
        (Outcome::Fail(f), Verdict::Pass) => {
            Err(format!("{imp}: declared pass, but failing {}", json!(sorted(f.clone()))))
        }
        (o, d) => Err(format!("{imp}: declared {d:?}, got {o:?}")),
    }
}

fn sorted(mut f: Vec<Failing>) -> Vec<Failing> {
    f.sort_by(|a, b| a.id.cmp(&b.id));
    f
}

fn outcome_from_json(v: &Value) -> Outcome {
    match v["outcome"].as_str() {
        Some("pass") => Outcome::Pass,
        Some("fail") => Outcome::Fail(serde_json::from_value(v["failing"].clone()).unwrap_or_default()),
        Some("error") => Outcome::Error(v["error"].as_str().unwrap_or("").to_string()),
        _ => Outcome::Error(format!("an unknown outcome in {v}")),
    }
}

fn outcome_json(o: &Outcome) -> Value {
    match o {
        Outcome::Pass => json!({ "outcome": "pass" }),
        Outcome::Fail(f) => json!({ "outcome": "fail", "failing": f }),
        Outcome::Error(e) => json!({ "outcome": "error", "error": e }),
        Outcome::CannotRun => json!({ "outcome": "cannot-run" }),
    }
}

fn arg(name: &str) -> Option<String> {
    let prefix = format!("--{name}=");
    std::env::args().find_map(|a| a.strip_prefix(&prefix).map(str::to_string))
}

/// The child's main: start the fake at `TS_SOCKET` with the scenario's
/// rules, then the application, run the steps, print one result line.
pub fn child_main() -> i32 {
    let env: BTreeMap<String, String> = std::env::vars().collect();
    let outcome = match (arg("scenario"), arg("qml"), std::env::var_os("TS_SOCKET")) {
        (Some(path), Some(qml), Some(socket)) => run_child(Path::new(&path), Path::new(&qml), Path::new(&socket)),
        _ => Outcome::Error("the child needs --scenario, --qml and TS_SOCKET".into()),
    };
    let mut line = outcome_json(&outcome);
    line["env"] = json!(env);
    println!("{RESULT_PREFIX}{line}");
    let _ = std::io::stdout().flush();
    0
}

fn run_child(path: &Path, qml: &Path, socket: &Path) -> Outcome {
    if let Err(e) = crate::checked_max_iterations() {
        return Outcome::Error(e);
    }
    let scenario = match Scenario::read(path) {
        Ok(s) => s,
        Err(e) => return Outcome::Error(e),
    };
    let app = headless_app();
    let fake = Fake::start(socket);
    if let Some(e) = fake.error() {
        return Outcome::Error(format!("the fake did not listen: {e}"));
    }
    if let Err(e) = fake.set_script(scenario.fake.clone()) {
        return Outcome::Error(format!("fake.{e}"));
    }
    let mut run = Run { app: &app, fake: &fake, qml, loaded: None, contract: Contract::new(), failing: Vec::new() };
    let result = scenario.steps.iter().enumerate().try_for_each(|(i, step)| {
        run.step(step).map_err(|e| format!("steps[{i}]: {e}"))?;
        run.exit_if_asked();
        Ok::<(), String>(())
    });
    let unmatched: Vec<String> =
        fake.requests().iter().filter(|r| r.unmatched).map(|r| format!("{} {}", r.method(), r.target())).collect();
    let unused = fake.armed_hold().map(|f| format!("a hold was armed for {} and never used", json!(Bytes(f))));
    let outcome = conclude(result, unused, &unmatched, &fake.faults(), &run.failing);
    drop(run.loaded.take());
    outcome
}

/// A child's outcome from its steps' `result`, an armed hold never used,
/// the requests no rule matched, the fake's own faults and the failed
/// expectations. A fault in the fake comes first: a wait it made
/// unreachable is not the implementation's doing.
pub fn conclude(
    result: Result<(), String>,
    unused: Option<String>,
    unmatched: &[String],
    faults: &[String],
    failing: &[Failing],
) -> Outcome {
    match (result, unused) {
        _ if !faults.is_empty() => Outcome::Error(format!("the fake failed: {}", faults.join("; "))),
        (Err(e), _) | (Ok(()), Some(e)) => Outcome::Error(e),
        (Ok(()), None) if !unmatched.is_empty() => {
            Outcome::Error(format!("the fake answered unmatched requests with 404: {}", unmatched.join(", ")))
        }
        (Ok(()), None) if failing.is_empty() => Outcome::Pass,
        (Ok(()), None) => Outcome::Fail(failing.to_vec()),
    }
}
