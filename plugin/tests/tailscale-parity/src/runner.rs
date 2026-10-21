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

use cxx_qt_lib::QGuiApplication;
use fake_tailscaled::scenario::{
    ClientSelector, Declaration, Expect, Failing, FakeOp, Implementation as Known, Scenario, Step, Verdict, Wait,
};
use fake_tailscaled::{Bytes, Fake, Match};
use serde_json::{json, Value};

use crate::child::{self, PrivateRoot};
use crate::contract::Contract;
use crate::implementation::Implementation;
use crate::{headless_app, load_driver, wait_until, Loaded};

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
        let socket = root.path().join("run/tailscaled.sock");
        let args = [
            "--child=scenario".to_string(),
            format!("--scenario={}", path.display()),
            format!("--qml={}", imp.qml_dir.display()),
        ];
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let mut env = vec![("TS_SOCKET", socket.to_str().unwrap_or(""))];
        env.extend_from_slice(extra);
        match child::isolated(&args, &root, &env).output() {
            Err(e) => report.outcome = Outcome::Error(format!("cannot start the child: {e}")),
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
                report.log = stdout.clone() + &String::from_utf8_lossy(&out.stderr);
                let line = stdout.lines().rev().find_map(|l| l.strip_prefix(RESULT_PREFIX));
                match line.map(serde_json::from_str::<Value>) {
                    Some(Ok(v)) => {
                        report.outcome = outcome_from_json(&v);
                        report.env = serde_json::from_value(v["env"].clone()).ok();
                    }
                    Some(Err(e)) => report.outcome = Outcome::Error(format!("a malformed result line: {e}")),
                    None => {
                        report.outcome =
                            Outcome::Error(format!("no result line (the child exited with {})", out.status))
                    }
                }
            }
        }
    }
    report.verdict = compare(&imp.name, &report.outcome, declaration);
    drop(root);
    report
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
    let outcome = match (result, unused) {
        (Err(e), _) | (Ok(()), Some(e)) => Outcome::Error(e),
        (Ok(()), None) if !unmatched.is_empty() => {
            Outcome::Error(format!("the fake answered unmatched requests with 404: {}", unmatched.join(", ")))
        }
        (Ok(()), None) if run.failing.is_empty() => Outcome::Pass,
        (Ok(()), None) => Outcome::Fail(run.failing.clone()),
    };
    drop(run.loaded.take());
    outcome
}

/// What an expectation asks for, for the log.
fn wanted(e: &Expect) -> Value {
    match (&e.contract, &e.signal, &e.request, &e.requests) {
        (Some(values), ..) => json!(values),
        (_, Some(s), ..) => json!({ "signal": s.name, "count": s.count }),
        (_, _, Some(r), _) => json!(r.raw),
        (_, _, _, Some(r)) => json!({ "requests": r.count }),
        _ => Value::Null,
    }
}

struct Run<'a> {
    app: &'a QGuiApplication,
    fake: &'a Fake,
    qml: &'a Path,
    loaded: Option<Loaded>,
    contract: Contract,
    failing: Vec<Failing>,
}

impl Run<'_> {
    /// QML asked the application to exit: the child ends there, with that
    /// code and no result line, as a crash would.
    fn exit_if_asked(&self) {
        if let Some(code) = self.loaded.as_ref().and_then(Loaded::exit_code) {
            let _ = std::io::stdout().flush();
            std::process::exit(code);
        }
    }

    /// Pumps until `done` holds; an error from it ends the wait at once.
    fn wait(&self, what: &str, mut done: impl FnMut() -> Result<bool, String>) -> Result<(), String> {
        let mut last = Ok(false);
        let reached = wait_until(self.app, || {
            last = done();
            match &last {
                Ok(true) => Some(()),
                Ok(false) => None,
                Err(_) => Some(()),
            }
        });
        match (reached, last) {
            (_, Err(e)) => Err(e),
            (Some(()), _) => Ok(()),
            (None, _) => Err(format!("wait never reached: {what}")),
        }
    }

    /// A scenario value as the contract reports it: `{"enum": key}`
    /// resolved to its integer.
    fn resolve(&self, v: &Value) -> Result<Value, String> {
        match v.get("enum").and_then(Value::as_str) {
            Some(key) => self.contract.enum_value(key),
            None => Ok(v.clone()),
        }
    }

    fn matching(&self, m: &Match) -> Vec<fake_tailscaled::Request> {
        self.fake.requests().into_iter().filter(|r| m.matches(r)).collect()
    }

    fn step(&mut self, step: &Step) -> Result<(), String> {
        match step {
            Step::Start(_) => {
                self.loaded = Some(load_driver(self.app, self.qml)?);
                Ok(())
            }
            Step::Call(c) => self.contract.call(&c.name, &c.args).map(drop),
            Step::Wait(Wait::Contract(values)) => {
                let mut wanted = Vec::new();
                for (member, v) in values {
                    wanted.push((member.clone(), v.clone(), self.resolve(v)?));
                }
                let what: Vec<String> = wanted.iter().map(|(m, v, _)| format!("{m} {v}")).collect();
                let mut last = BTreeMap::new();
                let reached = self.wait(&what.join(", "), || {
                    for (member, _, want) in &wanted {
                        let got = self.contract.read(member)?;
                        let equal = got == *want;
                        last.insert(member.clone(), got);
                        if !equal {
                            return Ok(false);
                        }
                    }
                    Ok(true)
                });
                reached.map_err(|e| format!("{e} (last read {})", json!(last)))
            }
            Step::Wait(Wait::Signal(s)) => self.wait(&format!("{} fired {} times", s.name, s.at_least), || {
                Ok(self.contract.signal_count(&s.name)? >= s.at_least)
            }),
            Step::Wait(Wait::Fake(f)) => {
                if let Some(n) = f.connected {
                    self.wait(&format!("the fake has {n} connected clients"), || Ok(self.fake.connected_count() == n))
                } else if let Some(m) = &f.recorded {
                    let n = f.count.unwrap_or(1);
                    self.wait(&format!("the fake recorded {n} of {}", json!(m)), || Ok(self.matching(m).len() >= n))
                } else {
                    let n = f.held.unwrap_or(0);
                    self.wait(&format!("the fake holds {n} requests"), || Ok(self.fake.held_count() == n))
                }
            }
            Step::Fake(op) => self.fake_op(op),
            Step::Barrier(b) => Err(format!("the {b:?} barrier needs a capability this implementation lacks")),
            Step::AdvanceMs(_) => Err("advance_ms needs the clock, which this implementation lacks".into()),
            Step::Expect(e) => self.expect(e),
        }
    }

    /// Runs one fake op. A push, resume or completion that reaches no
    /// client is an error: the count it returns is the barrier (R-FAKE-02).
    fn fake_op(&self, op: &FakeOp) -> Result<(), String> {
        let reached = |op: &str, n: usize| if n == 0 { Err(format!("{op} reached no client")) } else { Ok(()) };
        match op {
            FakeOp::PushLine(b) => reached("push_line", self.fake.push_line(&b.0))?,
            FakeOp::PushChunk(b) => reached("push_chunk", self.fake.push_chunk(&b.0))?,
            FakeOp::PushWatchLine(b) => reached("push_watch_line", self.fake.push_watch_line(&b.0))?,
            FakeOp::HoldNext(b) => self.fake.hold_next(&b.0),
            FakeOp::CompleteHeld(reply) => {
                reached("complete_held", self.fake.complete_held(&reply.encode(false)?.bytes))?
            }
            FakeOp::Resume(label) => reached("resume", self.fake.resume(label))?,
            FakeOp::CloseClient(sel) => {
                let id = match sel {
                    ClientSelector::Holding(b) => self.fake.client_holding(&b.0),
                    ClientSelector::Stream(_) => {
                        self.fake.clients().iter().find(|c| c.stream && c.connected).map(|c| c.id)
                    }
                    ClientSelector::Index(n) => Some(*n),
                };
                let id = id.ok_or_else(|| format!("no client for close_client {sel:?}"))?;
                if !self.fake.close_client(id) {
                    return Err(format!("client {id} was not connected"));
                }
            }
        }
        Ok(())
    }

    fn expect(&mut self, e: &Expect) -> Result<(), String> {
        let (ok, actual) = if let Some(values) = &e.contract {
            let mut ok = true;
            let mut actual = serde_json::Map::new();
            for (member, v) in values {
                let got = self.contract.read(member)?;
                ok &= got == self.resolve(v)?;
                actual.insert(member.clone(), got);
            }
            let actual = if actual.len() == 1 { actual.into_iter().next().unwrap().1 } else { Value::Object(actual) };
            (ok, actual)
        } else if let Some(s) = &e.signal {
            let n = self.contract.signal_count(&s.name)?;
            (n == s.count, json!(n))
        } else if let Some(r) = &e.request {
            let found = self.matching(&r.matcher);
            match found.iter().find(|q| q.raw != r.raw.0) {
                Some(differs) => (false, json!(Bytes(differs.raw.clone()))),
                None if found.is_empty() => (false, Value::Null),
                None => (true, json!(Bytes(found[0].raw.clone()))),
            }
        } else if let Some(r) = &e.requests {
            let n = self.matching(&r.matcher).len();
            (n == r.count, json!(n))
        } else {
            return Err(format!("expect `{}` has no kind", e.id));
        };
        if ok {
            return Ok(());
        }
        if e.precondition {
            return Err(format!("precondition `{}` failed: actual {actual}", e.id));
        }
        // The log the parent prints on a mismatch shows both values.
        println!("expect `{}` failed: wanted {}, actual {actual}", e.id, wanted(e));
        self.failing.push(Failing { id: e.id.clone(), actual });
        Ok(())
    }
}
