//! The steps of one scenario, run in the child against the loaded driver
//! and the fake: calls, waits, fake ops and expectations.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use cxx_qt_lib::QGuiApplication;
use fake_tailscaled::scenario::{ClientSelector, Expect, Failing, FakeOp, Step, Wait};
use fake_tailscaled::{Bytes, Fake, Match};
use serde_json::{json, Value};

use crate::contract::Contract;
use crate::model;
use crate::{load_driver, wait_until, Loaded};

/// What an expectation asks for, for the log.
fn wanted(e: &Expect) -> Value {
    if let Some(q) = &e.model {
        return json!(q.describe());
    }
    if let Some(r) = &e.request_parts {
        return json!({ "starts_with": r.starts_with, "headers": r.headers, "body_json": r.body_json });
    }
    match (&e.contract, &e.signal, &e.request, &e.requests) {
        (Some(values), ..) => json!(values),
        (_, Some(s), ..) => json!({ "signal": s.name, "count": s.count, "since": s.since }),
        (_, _, Some(r), _) => json!(r.raw),
        (_, _, _, Some(r)) => json!({ "requests": r.count }),
        _ => Value::Null,
    }
}

pub(crate) struct Run<'a> {
    pub(crate) app: &'a QGuiApplication,
    pub(crate) fake: &'a Fake,
    pub(crate) qml: &'a Path,
    pub(crate) loaded: Option<Loaded>,
    pub(crate) contract: Contract,
    pub(crate) failing: Vec<Failing>,
    /// Each mark's label and every counted signal's count at that step.
    pub(crate) marks: BTreeMap<String, BTreeMap<String, u64>>,
}

impl Run<'_> {
    /// QML asked the application to exit: the child ends there, with that
    /// code and no result line, as a crash would.
    pub(crate) fn exit_if_asked(&self) {
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

    fn matching(&self, m: &Match) -> Vec<fake_tailscaled::Request> {
        self.fake.requests().into_iter().filter(|r| m.matches(r)).collect()
    }

    pub(crate) fn step(&mut self, step: &Step) -> Result<(), String> {
        match step {
            Step::Start(_) => {
                self.loaded = Some(load_driver(self.app, self.qml)?);
                Ok(())
            }
            Step::Call(c) => self.contract.call(&c.name, &c.args).map(drop),
            Step::Wait(w) => self.wait_step(w),
            Step::Fake(op) => self.fake_op(op),
            Step::Barrier(b) => Err(format!("the {b:?} barrier needs a capability this implementation lacks")),
            Step::AdvanceMs(_) => Err("advance_ms needs the clock, which this implementation lacks".into()),
            Step::Mark(label) => {
                self.marks.insert(label.clone(), self.contract.signal_counts()?);
                Ok(())
            }
            Step::Expect(e) => self.expect(e),
        }
    }

    /// Runs one wait step until it holds; one never reached is an error.
    fn wait_step(&self, w: &Wait) -> Result<(), String> {
        match w {
            Wait::Contract(values) => {
                let mut wanted = Vec::new();
                for (member, v) in values {
                    wanted.push((member.clone(), v.clone(), self.contract.resolve(v)?));
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
            Wait::Signal(s) => {
                let since = s.since.as_ref().map(|m| format!(" since {m}")).unwrap_or_default();
                self.wait(&format!("{} fired {} times{since}", s.name, s.at_least), || {
                    Ok(self.signal_count_since(&s.name, s.since.as_deref())? >= s.at_least)
                })
            }
            Wait::Model(q) => {
                let mut last = Value::Null;
                let reached = self.wait(&q.describe(), || {
                    let (ok, read) = model::read(&self.contract, q)?;
                    last = read;
                    Ok(ok)
                });
                reached.map_err(|e| format!("{e} (last read {last})"))
            }
            Wait::Fake(f) => {
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

    /// How often signal `name` fired since load, or since mark `since`.
    fn signal_count_since(&self, name: &str, since: Option<&str>) -> Result<u64, String> {
        let now = self.contract.signal_count(name)?;
        let Some(label) = since else { return Ok(now) };
        let mark = self.marks.get(label).ok_or_else(|| format!("no mark `{label}` was reached"))?;
        let then = mark.get(name).ok_or_else(|| format!("mark `{label}` counted no signal {name}"))?;
        now.checked_sub(*then).ok_or_else(|| format!("{name} fell from {then} at mark `{label}` to {now}"))
    }

    /// Whether every recorded request `m` matches passes `check`, with at
    /// least one: the first that fails is the actual value, as its bytes,
    /// and none at all reads null.
    fn every_request(
        &self,
        m: &Match,
        check: impl Fn(&fake_tailscaled::Request) -> Result<(), String>,
    ) -> (bool, Value) {
        let found = self.matching(m);
        match found.iter().map(|q| (q, check(q))).find(|(_, c)| c.is_err()) {
            Some((differs, why)) => {
                println!("request {} {}: {}", differs.method(), differs.target(), why.unwrap_err());
                (false, json!(Bytes(differs.raw.clone())))
            }
            None if found.is_empty() => (false, Value::Null),
            None => (true, json!(Bytes(found[0].raw.clone()))),
        }
    }

    fn expect(&mut self, e: &Expect) -> Result<(), String> {
        let (ok, actual) = if let Some(values) = &e.contract {
            let mut ok = true;
            let mut actual = serde_json::Map::new();
            for (member, v) in values {
                let got = self.contract.read(member)?;
                ok &= got == self.contract.resolve(v)?;
                actual.insert(member.clone(), got);
            }
            (ok, model::one_or_all(actual))
        } else if let Some(s) = &e.signal {
            let n = self.signal_count_since(&s.name, s.since.as_deref())?;
            (n == s.count, json!(n))
        } else if let Some(r) = &e.request {
            self.every_request(&r.matcher, |q| if q.raw == r.raw.0 { Ok(()) } else { Err("other bytes".into()) })
        } else if let Some(r) = &e.request_parts {
            self.every_request(&r.matcher, |q| r.check(q))
        } else if let Some(r) = &e.requests {
            let n = self.matching(&r.matcher).len();
            (n == r.count, json!(n))
        } else if let Some(q) = &e.model {
            model::read(&self.contract, q)?
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
