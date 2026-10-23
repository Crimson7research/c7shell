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

mod check;
mod declare;
pub(crate) mod files;
mod handlers;
mod kept;
mod members;
mod model;
mod request;

pub use check::check_value;
use check::{check_expect, check_fake_wait, check_values, is_requirement_id};
pub(crate) use declare::{validate_declarations, Declared};
pub use handlers::HandlerCheck;
pub use kept::{Keep, KeptCheck};
pub use members::{Assign, MEMBER_TYPES};
pub use model::{role, ModelQuery, Role};
pub use request::RequestParts;

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
    /// Records every counted signal under this label, for a signal
    /// expectation's `since`.
    Mark(String),
    /// Stores a member's value under a label, for a `kept` expect.
    Keep(Keep),
    /// From here on, the driver reads these members inside every counted
    /// signal's handler, for a `handlers` expect.
    WatchHandlers(Vec<String>),
    Expect(Box<Expect>),
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
    /// Until the signal has fired at least this often since start, or
    /// since the mark its `since` names.
    Signal(SignalWait),
    /// Until the fake reports this.
    Fake(FakeWait),
    /// Until the model query holds.
    Model(ModelQuery),
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignalWait {
    pub name: String,
    pub at_least: u64,
    /// Count from this earlier `mark` step, not from load.
    pub since: Option<String>,
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
    /// Stops the fake: every client closed and nothing at the socket path,
    /// its records kept.
    Stop(Empty),
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
    /// Every recorded request that matches has these parts, and one
    /// matches.
    pub request_parts: Option<RequestParts>,
    /// Exactly `count` recorded requests match.
    pub requests: Option<RequestCount>,
    /// The model query holds.
    pub model: Option<ModelQuery>,
    /// Kept values differ pairwise, or one is still a member's.
    pub kept: Option<KeptCheck>,
    /// What the watched members read inside the named signals' handlers.
    pub handlers: Option<HandlerCheck>,
    /// Assigning the member from QML throws.
    pub assign: Option<Assign>,
    /// Each member reads as its type.
    pub member_types: Option<BTreeMap<String, String>>,
    /// `Tailscale` is one object per engine: the same one again in this
    /// engine, another in a second engine.
    pub singleton: Option<Empty>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SignalCount {
    pub name: String,
    pub count: u64,
    /// Count from this earlier `mark` step, not from load.
    pub since: Option<String>,
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
    /// parent has already loaded it with [`Scenario::load_for`]. A body
    /// `{"file": path}` is read from under the fixture root, the parent of
    /// the scenario's directory.
    pub fn read(path: &Path) -> Result<Scenario, String> {
        let at = |e: String| format!("{}: {e}", path.display());
        let text = std::fs::read_to_string(path).map_err(|e| at(e.to_string()))?;
        let mut value: Value = serde_json::from_str(&text).map_err(|e| at(e.to_string()))?;
        let root = path.parent().and_then(Path::parent).ok_or_else(|| at("no fixture root above it".into()))?;
        if !files::resolve_bodies(&mut value, root).map_err(at)? {
            // Parsed from the text, its errors keep their line and column.
            return serde_json::from_str(&text).map_err(|e| at(e.to_string()));
        }
        serde_json::from_value(value).map_err(|e| at(e.to_string()))
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
            Step::Expect(e) => Some(e.as_ref()),
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
        check::validate_marks(&self.steps)?;
        kept::validate_keeps(&self.steps)?;
        handlers::validate_handlers(&self.steps)?;
        let declared = Declared { tag: self.tag, needs: &self.needs, on: &self.on };
        validate_declarations(&declared, implementations, &|id| self.failing_id(id))
    }

    /// Whether a declared failing `id` is an expect that may fail.
    fn failing_id(&self, id: &str) -> Result<(), String> {
        let e = self.expects().find(|e| e.id == id).ok_or_else(|| format!("failing: no expect `{id}`"))?;
        if e.precondition {
            return Err(format!("failing: `{id}` is a precondition, which is setup, never the declared failure"));
        }
        Ok(())
    }

    fn validate_steps(&self) -> Result<(), String> {
        let starts: Vec<usize> =
            self.steps.iter().enumerate().filter(|(_, s)| matches!(s, Step::Start(_))).map(|(i, _)| i).collect();
        if starts != [0] {
            return Err("steps: `start` must be the first step, and only once".into());
        }
        let mut ids = BTreeSet::new();
        let mut stopped = false;
        for (i, step) in self.steps.iter().enumerate() {
            let at = |e: String| format!("steps[{i}].{e}");
            match step {
                Step::Fake(FakeOp::Stop(_)) if stopped => {
                    return Err(at("fake.stop: the fake is already stopped".into()))
                }
                Step::Fake(FakeOp::Stop(_)) => stopped = true,
                Step::Expect(e) if e.singleton.is_some() && i + 1 < self.steps.len() => {
                    return Err(at(format!("expect `{}`: singleton must be the last step", e.id)))
                }
                Step::Wait(Wait::Contract(values)) => {
                    check_values(values).map_err(|e| at(format!("wait.contract.{e}")))?
                }
                Step::Wait(Wait::Fake(f)) => check_fake_wait(f).map_err(|e| at(format!("wait.fake: {e}")))?,
                Step::Wait(Wait::Model(q)) => q.validate().map_err(|e| at(format!("wait.model: {e}")))?,
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
}
