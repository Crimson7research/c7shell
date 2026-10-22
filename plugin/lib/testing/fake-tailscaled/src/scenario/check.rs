//! The format's checks on values, waits and expectations, which need no Qt.

use std::collections::BTreeMap;

use serde_json::Value;

use super::{Expect, FakeWait};

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
    ];
    if kinds.iter().filter(|&&k| k).count() != 1 {
        return Err(
            "give exactly one of contract, signal, request, request_parts, requests, model, kept and handlers".into()
        );
    }
    if let Some(q) = &e.model {
        q.validate().map_err(|m| format!("model: {m}"))?;
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
