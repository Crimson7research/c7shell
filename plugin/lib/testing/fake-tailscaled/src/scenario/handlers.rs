//! Reads inside handlers: a `watch_handlers` step names the members the
//! driver reads inside every counted signal's handler from then on, and a
//! `handlers` expect checks what those reads saw.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::Value;

use super::check::check_values;
use super::Step;

/// Every firing of each of `signals`, since the mark `since` or else since
/// the watch, read `values`, and each signal fired at least once.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HandlerCheck {
    pub signals: Vec<String>,
    pub since: Option<String>,
    pub values: BTreeMap<String, Value>,
}

impl HandlerCheck {
    pub fn validate(&self) -> Result<(), String> {
        if self.signals.is_empty() {
            return Err("signals: empty".into());
        }
        check_values(&self.values).map_err(|e| {
            if e.starts_with("empty") {
                format!("values: {e}")
            } else {
                format!("values.{e}")
            }
        })
    }
}

/// One watch, of distinct members, before any `handlers` expect, which
/// reads only watched members.
pub(super) fn validate_handlers(steps: &[Step]) -> Result<(), String> {
    let mut watched: Option<BTreeSet<&str>> = None;
    for (i, step) in steps.iter().enumerate() {
        match step {
            Step::WatchHandlers(_) if watched.is_some() => {
                return Err(format!("steps[{i}].watch_handlers: a scenario watches handlers once"))
            }
            Step::WatchHandlers(members) if members.is_empty() => {
                return Err(format!("steps[{i}].watch_handlers: empty"))
            }
            Step::WatchHandlers(members) => {
                let mut set = BTreeSet::new();
                if let Some(twice) = members.iter().find(|m| !set.insert(m.as_str())) {
                    return Err(format!("steps[{i}].watch_handlers: `{twice}` twice"));
                }
                watched = Some(set);
            }
            Step::Expect(e) => {
                let Some(h) = &e.handlers else { continue };
                let at = |m: String| format!("steps[{i}].expect `{}`: handlers: {m}", e.id);
                let Some(set) = &watched else { return Err(at("no earlier watch_handlers".into())) };
                if let Some(member) = h.values.keys().find(|m| !set.contains(m.as_str())) {
                    return Err(at(format!("`{member}` is not watched")));
                }
            }
            _ => {}
        }
    }
    Ok(())
}
