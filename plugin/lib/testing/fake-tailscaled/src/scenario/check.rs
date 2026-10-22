//! The format's checks on values, waits and expectations, which need no Qt.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::{Expect, FakeWait, SignalWait, Step, Wait};

/// `R-` + capital letters + `-` + two digits.
pub(super) fn is_requirement_id(id: &str) -> bool {
    let Some(rest) = id.strip_prefix("R-") else { return false };
    let Some((area, number)) = rest.split_once('-') else { return false };
    !area.is_empty()
        && area.bytes().all(|b| b.is_ascii_uppercase())
        && number.len() == 2
        && number.bytes().all(|b| b.is_ascii_digit())
}

/// A contract value a scenario can compare: a JSON scalar, `{"enum": name}`,
/// `{"date": null | ISO string}`, `{"undefined": true}` (no value, as a
/// model's `data()` off the end returns), a string matcher
/// (`{"non_empty": true}` or `{"contains": non-empty text}`), a model as its
/// row count (`{"rows": n}`), or an array of such values (a string list,
/// such as `issues`).
pub fn check_value(value: &Value) -> Result<(), String> {
    match value {
        Value::Object(map) if map.len() == 1 => match map.iter().next().unwrap() {
            (k, Value::String(_)) if k == "enum" => Ok(()),
            (k, Value::String(_) | Value::Null) if k == "date" => Ok(()),
            (k, Value::Bool(true)) if k == "undefined" || k == "non_empty" => Ok(()),
            (k, Value::Number(n)) if k == "rows" && n.is_u64() => Ok(()),
            (k, Value::String(s)) if k == "contains" && !s.is_empty() => Ok(()),
            _ => Err(format!(
                "{value} is not {{\"enum\": name}}, {{\"date\": null | string}}, {{\"undefined\": true}}, \
                 {{\"non_empty\": true}}, {{\"contains\": text}} or {{\"rows\": n}}"
            )),
        },
        Value::Array(items) => items.iter().try_for_each(check_value),
        Value::Object(_) => Err(format!("{value} is not a scalar, an enum, a date or an array of them")),
        _ => Ok(()),
    }
}

pub(super) fn check_values(values: &BTreeMap<String, Value>) -> Result<(), String> {
    if values.is_empty() {
        return Err("empty: name at least one member".into());
    }
    values.iter().try_for_each(|(member, v)| check_value(v).map_err(|e| format!("{member}: {e}")))
}

pub(super) fn check_fake_wait(f: &FakeWait) -> Result<(), String> {
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

pub(super) fn check_expect(e: &Expect) -> Result<(), String> {
    let kinds = [
        e.contract.is_some(),
        e.signal.is_some(),
        e.request.is_some(),
        e.request_parts.is_some(),
        e.requests.is_some(),
        e.model.is_some(),
        e.kept.is_some(),
        e.handlers.is_some(),
        e.assign.is_some(),
        e.member_types.is_some(),
        e.singleton.is_some(),
    ];
    if kinds.iter().filter(|&&k| k).count() != 1 {
        return Err(
            "give exactly one of contract, signal, request, request_parts, requests, model, kept, handlers, assign, \
             member_types and singleton"
                .into(),
        );
    }
    if let Some(q) = &e.model {
        q.validate().map_err(|m| format!("model: {m}"))?;
    }
    if let Some(a) = &e.assign {
        a.validate().map_err(|m| format!("assign: {m}"))?;
    }
    if let Some(types) = &e.member_types {
        super::members::check_member_types(types)
            .map_err(|m| format!("member_types{}{m}", if m.starts_with("empty") { ": " } else { "." }))?;
    }
    if let Some(h) = &e.handlers {
        h.validate().map_err(|m| format!("handlers: {m}"))?;
    }
    if let Some(k) = &e.kept {
        k.validate().map_err(|m| format!("kept: {m}"))?;
    }
    if let Some(values) = &e.contract {
        check_values(values).map_err(|m| format!("contract.{m}"))?;
    }
    if let Some(r) = &e.request {
        r.matcher.validate()?;
    }
    if let Some(r) = &e.request_parts {
        r.validate().map_err(|m| format!("request_parts.{m}"))?;
    }
    if let Some(r) = &e.requests {
        r.matcher.validate()?;
    }
    Ok(())
}

/// Each mark is named once, and each `since` names an earlier mark.
pub(super) fn validate_marks(steps: &[Step]) -> Result<(), String> {
    let mut marks = BTreeSet::new();
    for (i, step) in steps.iter().enumerate() {
        match step {
            Step::Mark(label) if label.trim().is_empty() => return Err(format!("steps[{i}].mark: empty")),
            Step::Mark(label) if !marks.insert(label.as_str()) => {
                return Err(format!("steps[{i}].mark: `{label}` twice"))
            }
            Step::Expect(e) => match e
                .signal
                .as_ref()
                .and_then(|s| s.since.as_deref())
                .or_else(|| e.handlers.as_ref().and_then(|h| h.since.as_deref()))
            {
                Some(label) if !marks.contains(label) => {
                    return Err(format!("steps[{i}].expect `{}`: since: no earlier mark `{label}`", e.id))
                }
                _ => {}
            },
            Step::Wait(Wait::Signal(SignalWait { since: Some(label), .. })) if !marks.contains(label.as_str()) => {
                return Err(format!("steps[{i}].wait: since: no earlier mark `{label}`"))
            }
            _ => {}
        }
    }
    Ok(())
}
