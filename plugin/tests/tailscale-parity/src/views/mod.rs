//! The view tests (#309): #286's views over the QML stand-in, driven from
//! Rust through `qml/views-driver.qml`.
//!
//! A body is a Rust function over [`Views`]. It sets the stand-in's
//! properties and acts on elements as the backend and a person would, and
//! records each acceptance check with [`Views::check`]: a check that does
//! not hold is a failing id with its actual value, and the body goes on. A
//! lookup that cannot go on is an `Err` (plan decision V6).

pub mod bodies;
pub mod run;
pub mod tree;
pub mod ui;

use fake_tailscaled::scenario::Failing;
use serde_json::{json, Value};

use crate::probe;

/// A view test body.
pub type Body = fn(&mut Views) -> Result<(), String>;

/// An object the driver handed out. Two handles are equal exactly when
/// they are the same object.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct El(pub u64);

/// What a command acts on: an element, or a name the driver resolves
/// (`Tailscale`, `pop.panel`, ...).
pub trait Target {
    fn target(&self) -> Value;
}

impl Target for El {
    fn target(&self) -> Value {
        json!({ "handle": self.0 })
    }
}

impl Target for &str {
    fn target(&self) -> Value {
        json!(self)
    }
}

/// The driver, and the checks a body has recorded.
#[derive(Debug, Default)]
pub struct Views {
    pub failing: Vec<Failing>,
    /// The views directory the tree was built from, for a static scan.
    pub views: std::path::PathBuf,
}

impl Views {
    pub fn new() -> Views {
        Views::default()
    }

    fn request(&self, cmd: Value) -> Result<Value, String> {
        let answer = probe::send(&cmd.to_string())?;
        let answer: Value = serde_json::from_str(&answer).map_err(|e| format!("the driver answered {answer}: {e}"))?;
        match (answer.get("error"), answer.get("value")) {
            (Some(e), _) => Err(format!("{}: {}", cmd["op"], e.as_str().map_or_else(|| e.to_string(), str::to_string))),
            (None, Some(v)) => Ok(v.clone()),
            (None, None) => Err(format!("the driver answered {answer}")),
        }
    }

    /// Records the check `id`: when it does not hold, as failing with
    /// `actual`.
    pub fn check(&mut self, id: &str, holds: bool, actual: Value) {
        if !holds {
            self.failing.push(Failing { id: id.to_string(), actual });
        }
    }

    /// Setup, not acceptance: `Err(what)` when `holds` is false, so a
    /// staging that did not take is an error, never the declared failure.
    pub fn require(&self, holds: bool, what: &str) -> Result<(), String> {
        if holds {
            Ok(())
        } else {
            Err(format!("precondition: {what}"))
        }
    }

    /// Member `name` of `t`, as JSON: an object as its handle, a colour as
    /// its `#rrggbb` or `#aarrggbb` text.
    pub fn get(&self, t: impl Target, name: &str) -> Result<Value, String> {
        self.request(json!({ "op": "get", "target": t.target(), "name": name }))
    }

    /// Sets member `name` of `t`, then the layout barrier.
    pub fn set(&mut self, t: impl Target, name: &str, value: Value) -> Result<(), String> {
        self.request(json!({ "op": "set", "target": t.target(), "name": name, "value": value }))?;
        self.layout()
    }

    /// Calls `name` on `t`, then the layout barrier.
    pub fn invoke(&mut self, t: impl Target, name: &str, args: Value) -> Result<Value, String> {
        let r = self.request(json!({ "op": "invoke", "target": t.target(), "name": name, "args": args }))?;
        self.layout()?;
        Ok(r)
    }

    /// The descendants of `t` named `name`, or all of them.
    pub fn find(&self, t: impl Target, name: Option<&str>) -> Result<Vec<El>, String> {
        let v = self.request(json!({ "op": "find", "target": t.target(), "name": name }))?;
        v.as_array().ok_or_else(|| format!("find answered {v}"))?.iter().map(el).collect()
    }

    /// The layout barrier.
    pub fn layout(&self) -> Result<(), String> {
        self.request(json!({ "op": "layout" })).map(|_| ())
    }

    /// The stand-in's calls since the last time, joined by spaces.
    pub fn calls(&self) -> Result<String, String> {
        let v = self.request(json!({ "op": "calls" }))?;
        let calls: Vec<&str> =
            v.as_array().ok_or_else(|| format!("calls answered {v}"))?.iter().filter_map(Value::as_str).collect();
        Ok(calls.join(" "))
    }

    /// The window's active focus item.
    pub fn focus(&self) -> Result<Option<El>, String> {
        match self.request(json!({ "op": "focus" }))? {
            Value::Null => Ok(None),
            v => el(&v).map(Some),
        }
    }

    /// The driver's `Date.now()`, in ms since the epoch.
    pub fn now(&self) -> Result<f64, String> {
        let v = self.request(json!({ "op": "now" }))?;
        v.as_f64().ok_or_else(|| format!("now answered {v}"))
    }

    /// Counts `signal` of `t` from here on.
    pub fn watch(&self, t: impl Target, signal: &str) -> Result<(), String> {
        self.request(json!({ "op": "watch", "target": t.target(), "signal": signal })).map(|_| ())
    }

    /// How often `signal` of `t` has fired since [`Views::watch`].
    pub fn fired(&self, t: impl Target, signal: &str) -> Result<u64, String> {
        let v = self.request(json!({ "op": "fired", "target": t.target(), "signal": signal }))?;
        v.as_u64().ok_or_else(|| format!("fired answered {v}"))
    }

    /// Member `name` of `t` as a string, or an error naming what it was.
    pub fn text(&self, t: impl Target, name: &str) -> Result<String, String> {
        match self.get(t, name)? {
            Value::String(s) => Ok(s),
            v => Err(format!("{name} is {v}, not a string")),
        }
    }

    /// Member `name` of `t` as a bool.
    pub fn flag(&self, t: impl Target, name: &str) -> Result<bool, String> {
        let v = self.get(t, name)?;
        v.as_bool().ok_or_else(|| format!("{name} is {v}, not a bool"))
    }

    /// Member `name` of `t` as a number.
    pub fn number(&self, t: impl Target, name: &str) -> Result<f64, String> {
        let v = self.get(t, name)?;
        v.as_f64().ok_or_else(|| format!("{name} is {v}, not a number"))
    }

    /// Member `name` of `t` as an element, or None for null.
    pub fn object(&self, t: impl Target, name: &str) -> Result<Option<El>, String> {
        match self.get(t, name)? {
            Value::Null => Ok(None),
            v => el(&v).map(Some),
        }
    }
}

fn el(v: &Value) -> Result<El, String> {
    v.get("handle").and_then(Value::as_u64).map(El).ok_or_else(|| format!("{v} is no element"))
}
