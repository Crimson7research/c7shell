//! Expects on `Tailscale`'s members themselves: assigning one from QML, and
//! the type each reads as.

use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

/// Assigns `value` to `member` from QML; holds when the assignment throws.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Assign {
    pub member: String,
    pub value: Value,
}

impl Assign {
    pub fn validate(&self) -> Result<(), String> {
        if self.member.is_empty() {
            return Err("empty member".into());
        }
        Ok(())
    }
}

/// The types a member can read as from QML. An enum and an int both read
/// as `number`, and a method's parameter types are not visible.
pub const MEMBER_TYPES: &[&str] = &["number", "string", "boolean", "date", "array", "model", "function"];

/// Each member reads as its type.
pub fn check_member_types(types: &BTreeMap<String, String>) -> Result<(), String> {
    if types.is_empty() {
        return Err("empty: name at least one member".into());
    }
    match types.iter().find(|(_, t)| !MEMBER_TYPES.contains(&t.as_str())) {
        Some((member, t)) => Err(format!("{member}: `{t}` is not one of {}", MEMBER_TYPES.join(", "))),
        None => Ok(()),
    }
}
