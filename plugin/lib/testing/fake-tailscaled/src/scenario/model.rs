//! The model query: one read of a list model member of `Tailscale`, such as
//! `peers` or `exitNodes`, used by a `model` wait and a `model` expect.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use super::check_value;

/// One read of the model member `name`, with exactly one of `count`,
/// `values`, `has_children` and `distinct_from`.
///
/// - `count`: `rowCount()`, or with `row` the row's child count.
/// - `values`: the roles of row `row`. A key is a role name, or `#<n>` for
///   role number `n` (`#0` is Qt's display role). A role read by name needs
///   a row that exists; one read by number can read any row.
/// - `has_children`: `hasChildren()`, of the root or with `row` of the row.
/// - `distinct_from`: another model member's name; holds when the two are
///   different objects.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelQuery {
    pub name: String,
    pub row: Option<i64>,
    pub count: Option<u64>,
    pub values: Option<BTreeMap<String, Value>>,
    pub has_children: Option<bool>,
    pub distinct_from: Option<String>,
}

/// A role key: a role name, or `#` and a whole number.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role<'a> {
    Name(&'a str),
    Number(u32),
}

/// What `key` names, or why it names nothing.
pub fn role(key: &str) -> Result<Role<'_>, String> {
    match key.strip_prefix('#') {
        _ if key.is_empty() => Err("role ``: empty; give a role name or #<number>".into()),
        Some(n) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => {
            n.parse().map(Role::Number).map_err(|_| format!("role `{key}`: the number is too large"))
        }
        Some(_) => Err(format!("role `{key}`: # must be followed by a whole number")),
        None => Ok(Role::Name(key)),
    }
}

impl ModelQuery {
    /// Every check the format makes on a model query.
    pub fn validate(&self) -> Result<(), String> {
        if self.name.is_empty() {
            return Err("name: empty; name the model member".into());
        }
        let kinds =
            [self.count.is_some(), self.values.is_some(), self.has_children.is_some(), self.distinct_from.is_some()];
        if kinds.iter().filter(|&&k| k).count() != 1 {
            return Err("give exactly one of count, values, has_children and distinct_from".into());
        }
        match (&self.distinct_from, self.row) {
            (Some(other), _) if other.is_empty() => return Err("distinct_from: empty; name the other member".into()),
            (Some(_), Some(_)) => return Err("distinct_from takes no row: it compares the members".into()),
            _ => {}
        }
        if let Some(row) = self.row.filter(|r| *r < 0) {
            return Err(format!("row: {row} is negative; an invalid index reads the root, not a row"));
        }
        let Some(values) = &self.values else { return Ok(()) };
        if self.row.is_none() {
            return Err("values needs a row".into());
        }
        if values.is_empty() {
            return Err("values: empty; name at least one role".into());
        }
        values.iter().try_for_each(|(key, v)| {
            role(key).map_err(|e| format!("values.{e}"))?;
            check_value(v).map_err(|e| format!("values.{key}: {e}"))
        })
    }

    /// What the query asks for, for a wait's message and the log.
    pub fn describe(&self) -> String {
        let at = self.row.map(|r| format!(" row {r}")).unwrap_or_default();
        match (&self.count, &self.values, &self.has_children) {
            (Some(n), ..) if self.row.is_some() => format!("{}{at} has {n} child rows", self.name),
            (Some(n), ..) => format!("{} has {n} rows", self.name),
            (_, Some(v), _) => format!("{}{at} reads {}", self.name, serde_json::json!(v)),
            (_, _, Some(h)) => format!("{}{at} has_children {h}", self.name),
            _ => match &self.distinct_from {
                Some(other) => format!("{} is not the object {other} is", self.name),
                None => self.name.clone(),
            },
        }
    }
}
