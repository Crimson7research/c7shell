//! `Contract`: synchronous reads and calls on the loaded `Tailscale`
//! singleton, each one `Probe` round trip returning JSON.
//!
//! Values come back as JSON: enums as integers, an invalid `Date` as
//! `{"date": null}` and a valid one as `{"date": "<ISO>"}`, a model as
//! `{"rows": n}`, a string list as an array.

use std::collections::BTreeMap;

use serde_json::{json, Value};

use crate::probe;

/// Whether `got`, as the driver read it, matches the resolved scenario
/// value `want`: `{"non_empty": true}` a non-empty string,
/// `{"contains": text}` a string holding `text`, an array element by
/// element, anything else by equality.
pub fn matches(got: &Value, want: &Value) -> bool {
    match (got, want) {
        (Value::Array(g), Value::Array(w)) => g.len() == w.len() && g.iter().zip(w).all(|(g, w)| matches(g, w)),
        (_, Value::Object(m)) if m.len() == 1 && (m.contains_key("non_empty") || m.contains_key("contains")) => {
            let Some(text) = got.as_str() else { return false };
            match m.get("contains").and_then(Value::as_str) {
                Some(part) => text.contains(part),
                None => !text.is_empty(),
            }
        }
        _ => got == want,
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Contract;

impl Contract {
    pub fn new() -> Contract {
        Contract
    }

    fn request(&self, cmd: Value) -> Result<Value, String> {
        let answer = probe::send(&cmd.to_string())?;
        let answer: Value = serde_json::from_str(&answer).map_err(|e| format!("the driver answered {answer}: {e}"))?;
        match (answer.get("error"), answer.get("value")) {
            (Some(e), _) => Err(e.as_str().map_or_else(|| e.to_string(), str::to_string)),
            (None, Some(v)) => Ok(v.clone()),
            (None, None) => Err(format!("the driver answered {answer}")),
        }
    }

    /// The value of property `name`.
    pub fn read(&self, name: &str) -> Result<Value, String> {
        self.request(json!({ "op": "read", "name": name }))
    }

    /// The integer value of enum key `key`, such as `Running`.
    pub fn enum_value(&self, key: &str) -> Result<Value, String> {
        self.request(json!({ "op": "enum", "key": key }))
    }

    /// A scenario value as the contract reports it: `{"enum": key}`
    /// resolved to its integer, inside an array too.
    pub fn resolve(&self, v: &Value) -> Result<Value, String> {
        match v {
            Value::Array(items) => items.iter().map(|i| self.resolve(i)).collect::<Result<_, _>>().map(Value::Array),
            _ => match v.get("enum").and_then(Value::as_str) {
                Some(key) => self.enum_value(key),
                None => Ok(v.clone()),
            },
        }
    }

    /// Calls invokable `name` with `args`.
    pub fn call(&self, name: &str, args: &[Value]) -> Result<Value, String> {
        self.request(json!({ "op": "call", "name": name, "args": args }))
    }

    /// How often signal `name` has fired since the driver loaded.
    pub fn signal_count(&self, name: &str) -> Result<u64, String> {
        let v = self.request(json!({ "op": "count", "name": name }))?;
        v.as_u64().ok_or_else(|| format!("count of {name} is {v}"))
    }

    /// Every counted signal's count since the driver loaded, by name.
    pub fn signal_counts(&self) -> Result<BTreeMap<String, u64>, String> {
        let v = self.request(json!({ "op": "counts" }))?;
        serde_json::from_value(v.clone()).map_err(|e| format!("the counts {v}: {e}"))
    }

    /// `rowCount()` of model member `name`, or with `row` that row's child
    /// count.
    pub fn model_rows(&self, name: &str, row: Option<i64>) -> Result<u64, String> {
        let v = self.request(json!({ "op": "rows", "name": name, "row": row }))?;
        v.as_u64().ok_or_else(|| format!("rowCount of {name} is {v}"))
    }

    /// `hasChildren()` of model member `name`'s root, or with `row` of that
    /// row.
    pub fn model_has_children(&self, name: &str, row: Option<i64>) -> Result<bool, String> {
        let v = self.request(json!({ "op": "has_children", "name": name, "row": row }))?;
        v.as_bool().ok_or_else(|| format!("hasChildren of {name} is {v}"))
    }

    /// Role `role` of row `row` of model member `name`: a role name, or
    /// `#<n>` for role number `n`. No value reads `{"undefined": true}`.
    pub fn model_data(&self, name: &str, row: i64, role: &str) -> Result<Value, String> {
        self.request(json!({ "op": "data", "name": name, "row": row, "role": role }))
    }

    /// Whether model members `name` and `other` are different objects.
    pub fn models_distinct(&self, name: &str, other: &str) -> Result<bool, String> {
        let v = self.request(json!({ "op": "distinct", "name": name, "other": other }))?;
        v.as_bool().ok_or_else(|| format!("distinct of {name} and {other} is {v}"))
    }

    /// Stores member `name`'s value in the driver under `label`.
    pub fn keep(&self, label: &str, name: &str) -> Result<(), String> {
        self.request(json!({ "op": "keep", "label": label, "name": name })).map(drop)
    }

    /// Whether the values kept under `labels` differ pairwise, and each
    /// value by label.
    pub fn kept_distinct(&self, labels: &[String]) -> Result<(bool, Value), String> {
        let v = self.request(json!({ "op": "kept_distinct", "labels": labels }))?;
        match (v.get("distinct").and_then(Value::as_bool), v.get("values")) {
            (Some(d), Some(values)) => Ok((d, values.clone())),
            _ => Err(format!("kept_distinct answered {v}")),
        }
    }

    /// Whether the value kept under `label` is still member `name`'s.
    pub fn kept_same(&self, label: &str, name: &str) -> Result<bool, String> {
        let v = self.request(json!({ "op": "kept_same", "label": label, "name": name }))?;
        v.as_bool().ok_or_else(|| format!("kept_same of {label} and {name} is {v}"))
    }

    /// From now on, the driver reads members `names` inside every counted
    /// signal's handler.
    pub fn watch_handlers(&self, names: &[String]) -> Result<(), String> {
        self.request(json!({ "op": "watch_handlers", "names": names })).map(drop)
    }

    /// How many handler firings the driver has read.
    pub fn firing_count(&self) -> Result<usize, String> {
        let v = self.request(json!({ "op": "firings" }))?;
        v.as_u64().map(|n| n as usize).ok_or_else(|| format!("the firing count is {v}"))
    }

    /// Each firing read from index `from` on, as `(signal, values)`.
    pub fn firings(&self, from: usize) -> Result<Vec<(String, Value)>, String> {
        let v = self.request(json!({ "op": "firings", "from": from }))?;
        let list = v.as_array().ok_or_else(|| format!("the firings are {v}"))?;
        list.iter()
            .map(|f| match (f.get("signal").and_then(Value::as_str), f.get("values")) {
                (Some(s), Some(values)) => Ok((s.to_string(), values.clone())),
                _ => Err(format!("a firing reads {f}")),
            })
            .collect()
    }

    /// Assigns `value` to member `name` from QML: whether that threw, and
    /// with what.
    pub fn assign(&self, name: &str, value: &Value) -> Result<(bool, Option<String>), String> {
        let v = self.request(json!({ "op": "assign", "name": name, "value": value }))?;
        let threw = v.get("threw").and_then(Value::as_bool).ok_or_else(|| format!("assign answered {v}"))?;
        Ok((threw, v.get("error").and_then(Value::as_str).map(str::to_string)))
    }

    /// The type member `name` reads as: number, string, boolean, date,
    /// array, model, function, or what `typeof` says of anything else.
    pub fn member_type(&self, name: &str) -> Result<String, String> {
        let v = self.request(json!({ "op": "type", "name": name }))?;
        v.as_str().map(str::to_string).ok_or_else(|| format!("the type of {name} is {v}"))
    }

    /// Every member name QML enumerates on `Tailscale`.
    pub fn members(&self) -> Result<Vec<String>, String> {
        let v = self.request(json!({ "op": "members" }))?;
        serde_json::from_value(v).map_err(|e| e.to_string())
    }
}
