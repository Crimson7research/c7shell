//! `Contract`: synchronous reads and calls on the loaded `Tailscale`
//! singleton, each one `Probe` round trip returning JSON.
//!
//! Values come back as JSON: enums as integers, an invalid `Date` as
//! `{"date": null}` and a valid one as `{"date": "<ISO>"}`, a model as
//! `{"rows": n}`, a string list as an array.

use serde_json::{json, Value};

use crate::probe;

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

    /// Every member name QML enumerates on `Tailscale`.
    pub fn members(&self) -> Result<Vec<String>, String> {
        let v = self.request(json!({ "op": "members" }))?;
        serde_json::from_value(v).map_err(|e| e.to_string())
    }
}
