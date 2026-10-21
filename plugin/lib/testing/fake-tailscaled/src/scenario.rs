//! The scenario format: one JSON file per scenario under
//! `tests/fixtures/tailscale/scenarios/`, run by the `tailscale-parity`
//! harness against a named implementation of the `C7` module.
//!
//! This module holds the types, the loader and every check that needs no Qt.
//! See `docs/superpowers/plans/2026-10-21-phase2-harness.md`, "Scenario
//! format".

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::bytes::Bytes;
use crate::reply::{watch_chunk, ReplySpec};
use crate::script::{within_write_limit, Match, Script};

/// What an implementation lets a scenario do beyond the contract and the
/// fake.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "kebab-case")]
pub enum Capability {
    /// The explicit-advance test clock.
    Clock,
    /// The retry hook: reconnects armed.
    RetryHook,
    /// The idle barrier.
    IdleBarrier,
    /// The read barrier.
    ReadBarrier,
    /// The clock's current instant.
    ClockHook,
}

/// An implementation's name and capabilities.
pub type Implementation<'a> = (&'a str, &'a [Capability]);

/// The implementations the runner knows. #286's C++ module at a38dbca has no
/// capabilities; Phase 3 adds the Rust module's.
pub const IMPLEMENTATIONS: &[Implementation<'static>] = &[("cpp-286", &[]), ("rust", &[])];

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Tag {
    Parity,
    Fix,
}

/// The evidence classes of `tests/fixtures/tailscale/evidence.json`.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum EvidenceClass {
    HarnessOnCpp,
    CppSuite,
    Phase3Only,
    FakeSelf,
    None,
}

/// One scenario file.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    pub format: u32,
    pub id: String,
    pub requirements: Vec<String>,
    pub tag: Tag,
    pub evidence: EvidenceClass,
    /// The acceptance clauses it runs, in prose.
    pub clauses: Vec<String>,
    /// The clauses of its requirements it does not run, and where they are.
    #[serde(default)]
    pub deferred: Vec<String>,
    pub needs: BTreeSet<Capability>,
    /// The fake's rules, as a [`Script`].
    pub fake: Script,
    pub steps: Vec<Step>,
    /// What each implementation is declared to do.
    pub on: BTreeMap<String, Declaration>,
}

/// One step, run in order.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Step {
    /// Load the driver, which touches `Tailscale` and so constructs it.
    Start(Empty),
    Call(Call),
    Wait(Wait),
    Fake(FakeOp),
    /// Needs the capability of that barrier.
    Barrier(BarrierKind),
    /// Needs the clock.
    AdvanceMs(u64),
    Expect(Expect),
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Empty {}

/// Calls an invokable on `Tailscale`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub name: String,
    #[serde(default)]
    pub args: Vec<Value>,
}

/// A positive wait. One the implementation never reaches is an error.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum Wait {
    /// Until each member reads its value.
    Contract(BTreeMap<String, Value>),
    /// Until the signal has fired at least this often since start.
    Signal(SignalWait),
    /// Until the fake reports this.
    Fake(FakeWait),
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignalWait {
    pub name: String,
    pub at_least: u64,
}

/// Exactly one of `connected` (the client barrier), `recorded` (with
/// `count`, 1 by default) and `held`.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FakeWait {
    pub connected: Option<usize>,
    pub recorded: Option<Match>,
    pub count: Option<usize>,
    pub held: Option<usize>,
}

/// Something the fake does.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum FakeOp {
    PushLine(Bytes),
    PushChunk(Bytes),
    PushWatchLine(Bytes),
    HoldNext(Bytes),
    CompleteHeld(ReplySpec),
    Resume(String),
    CloseClient(ClientSelector),
}

/// Which client a `close_client` closes.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
pub enum ClientSelector {
    /// The held client whose request contains these bytes.
    Holding(Bytes),
    /// The watch stream.
    Stream(bool),
    /// The client of this id, in accept order from 1.
    Index(usize),
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BarrierKind {
    Read,
    Idle,
    Retry,
}

impl BarrierKind {
    pub fn capability(self) -> Capability {
        match self {
            BarrierKind::Read => Capability::ReadBarrier,
            BarrierKind::Idle => Capability::IdleBarrier,
            BarrierKind::Retry => Capability::RetryHook,
        }
    }
}

/// One expectation, with exactly one of its kinds.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expect {
    pub id: String,
    /// Setup, not acceptance: a failed precondition is an error, never the
    /// declared failure.
    #[serde(default)]
    pub precondition: bool,
    /// Each member reads its value.
    pub contract: Option<BTreeMap<String, Value>>,
    /// The signal fired exactly `count` times since start.
    pub signal: Option<SignalCount>,
    /// Every recorded request that matches equals `raw`, and one matches.
    pub request: Option<RequestBytes>,
    /// Exactly `count` recorded requests match.
    pub requests: Option<RequestCount>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignalCount {
    pub name: String,
    pub count: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestBytes {
    #[serde(rename = "match")]
    pub matcher: Match,
    pub raw: Bytes,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestCount {
    #[serde(rename = "match")]
    pub matcher: Match,
    pub count: usize,
}

/// The declared result on one implementation.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Declaration {
    pub result: Verdict,
    /// For `fail`: exactly the expectations that fail, with their actual
    /// values.
    pub failing: Option<Vec<Failing>>,
    pub reason: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Verdict {
    Pass,
    Fail,
    CannotRun,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Failing {
    pub id: String,
    pub actual: Value,
}

impl Scenario {
    /// Loads and validates `path` against the runner's implementations.
    pub fn load(path: &Path) -> Result<Scenario, String> {
        Scenario::load_for(path, IMPLEMENTATIONS)
    }

    /// Loads and validates `path` against `implementations`.
    pub fn load_for(path: &Path, implementations: &[Implementation<'_>]) -> Result<Scenario, String> {
        let scenario = Scenario::read(path)?;
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        scenario.validate(stem, implementations).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(scenario)
    }

    /// Parses `path` without validating it: for a runner's child, whose
    /// parent has already loaded it with [`Scenario::load_for`].
    pub fn read(path: &Path) -> Result<Scenario, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The capabilities its steps need.
    pub fn derived_needs(&self) -> BTreeSet<Capability> {
        self.steps
            .iter()
            .filter_map(|s| match s {
                Step::AdvanceMs(_) => Some(Capability::Clock),
                Step::Barrier(b) => Some(b.capability()),
                _ => None,
            })
            .collect()
    }

    /// The expectations, in order.
    pub fn expects(&self) -> impl Iterator<Item = &Expect> {
        self.steps.iter().filter_map(|s| match s {
            Step::Expect(e) => Some(e),
            _ => None,
        })
    }

    /// Every check the format makes, for a file named `stem`.
    pub fn validate(&self, stem: &str, implementations: &[Implementation<'_>]) -> Result<(), String> {
        if self.format != 1 {
            return Err(format!("format: {} is not 1", self.format));
        }
        if self.id != stem {
            return Err(format!("id: `{}` differs from the file name `{stem}`", self.id));
        }
        if self.requirements.is_empty() {
            return Err("requirements: empty".into());
        }
        if let Some(bad) = self.requirements.iter().find(|r| !is_requirement_id(r)) {
            return Err(format!("requirements: `{bad}` is not an R-AREA-NN id"));
        }
        if self.clauses.is_empty() {
            return Err("clauses: empty; say which acceptance clauses this scenario runs".into());
        }
        let derived = self.derived_needs();
        if self.needs != derived {
            return Err(format!("needs: declared {:?}, but the steps need {derived:?}", self.needs));
        }
        if self.evidence == EvidenceClass::HarnessOnCpp && !self.needs.is_empty() {
            return Err(format!("evidence: harness-on-cpp needs no capability, but needs is {:?}", self.needs));
        }
        self.fake.validate().map_err(|e| format!("fake.{e}"))?;
        self.validate_steps()?;
        self.validate_declarations(implementations)
    }

    fn validate_steps(&self) -> Result<(), String> {
        let starts: Vec<usize> =
            self.steps.iter().enumerate().filter(|(_, s)| matches!(s, Step::Start(_))).map(|(i, _)| i).collect();
        if starts != [0] {
            return Err("steps: `start` must be the first step, and only once".into());
        }
        let mut ids = BTreeSet::new();
        for (i, step) in self.steps.iter().enumerate() {
            let at = |e: String| format!("steps[{i}].{e}");
            match step {
                Step::Wait(Wait::Contract(values)) => {
                    check_values(values).map_err(|e| at(format!("wait.contract.{e}")))?
                }
                Step::Wait(Wait::Fake(f)) => check_fake_wait(f).map_err(|e| at(format!("wait.fake: {e}")))?,
                Step::Expect(e) => {
                    check_expect(e).map_err(|m| at(format!("expect `{}`: {m}", e.id)))?;
                    if !ids.insert(e.id.as_str()) {
                        return Err(at(format!("expect: duplicate id `{}`", e.id)));
                    }
                }
                Step::Fake(FakeOp::CompleteHeld(reply)) => {
                    let encoded = reply.encode(false).map_err(|e| at(format!("fake.complete_held.{e}")))?;
                    within_write_limit("the reply", encoded.bytes.len())
                        .map_err(|e| at(format!("fake.complete_held: {e}")))?;
                }
                Step::Fake(FakeOp::PushLine(b)) => {
                    within_write_limit("the line", b.0.len() + 1).map_err(|e| at(format!("fake.push_line: {e}")))?
                }
                Step::Fake(FakeOp::PushChunk(b)) => {
                    within_write_limit("the chunk", b.0.len()).map_err(|e| at(format!("fake.push_chunk: {e}")))?
                }
                Step::Fake(FakeOp::PushWatchLine(b)) => within_write_limit("the chunk", watch_chunk(&b.0).len())
                    .map_err(|e| at(format!("fake.push_watch_line: {e}")))?,
                _ => {}
            }
        }
        Ok(())
    }

    fn validate_declarations(&self, implementations: &[Implementation<'_>]) -> Result<(), String> {
        if let Some((name, _)) = implementations.iter().find(|(n, _)| !self.on.contains_key(*n)) {
            return Err(format!("on.{name}: missing"));
        }
        if let Some(name) = self.on.keys().find(|k| !implementations.iter().any(|(n, _)| n == k)) {
            return Err(format!("on.{name}: not an implementation the runner knows"));
        }
        for (name, capabilities) in implementations {
            self.validate_declaration(name, capabilities, &self.on[*name]).map_err(|e| format!("on.{name}: {e}"))?;
        }
        Ok(())
    }

    fn validate_declaration(&self, name: &str, capabilities: &[Capability], d: &Declaration) -> Result<(), String> {
        let runnable = self.needs.iter().all(|n| capabilities.contains(n));
        match (d.result, runnable) {
            (Verdict::CannotRun, true) => {
                return Err(format!("cannot-run, but {name} has every capability this scenario needs"))
            }
            (Verdict::Pass | Verdict::Fail, false) => {
                return Err(format!("{:?} declared, but {name} lacks some of {:?}", d.result, self.needs))
            }
            _ => {}
        }
        match d.result {
            Verdict::Pass if d.failing.is_some() => return Err("failing: only a fail declares failing".into()),
            Verdict::Fail => self.validate_failing(d.failing.as_deref())?,
            Verdict::CannotRun if d.failing.is_some() => return Err("failing: cannot-run declares none".into()),
            _ => {}
        }
        if d.result != Verdict::Pass && d.reason.as_deref().is_none_or(|r| r.trim().is_empty()) {
            return Err("reason: a fail or cannot-run says why".into());
        }
        match (self.tag, name, d.result) {
            (Tag::Fix, "cpp-286", Verdict::Pass) => Err("a fix cannot pass on #286; declare fail or cannot-run".into()),
            (Tag::Parity, "cpp-286", Verdict::Fail) => Err("a parity scenario cannot fail on #286".into()),
            (_, "rust", Verdict::Fail) => Err("the rewrite is declared to pass, or cannot-run until it can".into()),
            _ => Ok(()),
        }
    }

    fn validate_failing(&self, failing: Option<&[Failing]>) -> Result<(), String> {
        let failing = failing.filter(|f| !f.is_empty()).ok_or("failing: a fail names the failing expectations")?;
        let mut seen = BTreeSet::new();
        for f in failing {
            let e = self.expects().find(|e| e.id == f.id).ok_or_else(|| format!("failing: no expect `{}`", f.id))?;
            if e.precondition {
                return Err(format!(
                    "failing: `{}` is a precondition, which is setup, never the declared failure",
                    f.id
                ));
            }
            if !seen.insert(f.id.as_str()) {
                return Err(format!("failing: `{}` named twice", f.id));
            }
        }
        Ok(())
    }
}

/// `R-` + capital letters + `-` + two digits.
fn is_requirement_id(id: &str) -> bool {
    let Some(rest) = id.strip_prefix("R-") else { return false };
    let Some((area, number)) = rest.split_once('-') else { return false };
    !area.is_empty()
        && area.bytes().all(|b| b.is_ascii_uppercase())
        && number.len() == 2
        && number.bytes().all(|b| b.is_ascii_digit())
}

/// A contract value a scenario can compare: a JSON scalar, `{"enum": name}`
/// or `{"date": null | ISO string}`.
pub fn check_value(value: &Value) -> Result<(), String> {
    match value {
        Value::Object(map) if map.len() == 1 => match map.iter().next().unwrap() {
            (k, Value::String(_)) if k == "enum" => Ok(()),
            (k, Value::String(_) | Value::Null) if k == "date" => Ok(()),
            _ => Err(format!("{value} is not {{\"enum\": name}} or {{\"date\": null | string}}")),
        },
        Value::Object(_) | Value::Array(_) => Err(format!("{value} is not a scalar, an enum or a date")),
        _ => Ok(()),
    }
}

fn check_values(values: &BTreeMap<String, Value>) -> Result<(), String> {
    if values.is_empty() {
        return Err("empty: name at least one member".into());
    }
    values.iter().try_for_each(|(member, v)| check_value(v).map_err(|e| format!("{member}: {e}")))
}

fn check_fake_wait(f: &FakeWait) -> Result<(), String> {
    let kinds = [f.connected.is_some(), f.recorded.is_some(), f.held.is_some()].iter().filter(|&&k| k).count();
    if kinds != 1 {
        return Err("give exactly one of connected, recorded and held".into());
    }
    if f.count.is_some() && f.recorded.is_none() {
        return Err("count goes with recorded".into());
    }
    if let Some(m) = &f.recorded {
        m.validate()?;
    }
    Ok(())
}

fn check_expect(e: &Expect) -> Result<(), String> {
    let kinds = [e.contract.is_some(), e.signal.is_some(), e.request.is_some(), e.requests.is_some()]
        .iter()
        .filter(|&&k| k)
        .count();
    if kinds != 1 {
        return Err("give exactly one of contract, signal, request and requests".into());
    }
    if let Some(values) = &e.contract {
        check_values(values).map_err(|m| format!("contract.{m}"))?;
    }
    if let Some(r) = &e.request {
        r.matcher.validate()?;
    }
    if let Some(r) = &e.requests {
        r.matcher.validate()?;
    }
    Ok(())
}
