//! A scenario's model query, read through the driver: a row count, a
//! row's roles, or whether a row has children.

use fake_tailscaled::scenario::ModelQuery;
use serde_json::{json, Map, Value};

use crate::contract::Contract;

/// Whether `q` holds, and what was read: the count, the flag, or the roles
/// (one role's value alone, several as an object by role).
pub fn read(contract: &Contract, q: &ModelQuery) -> Result<(bool, Value), String> {
    if let Some(want) = q.count {
        let n = contract.model_rows(&q.name, q.row)?;
        return Ok((n == want, json!(n)));
    }
    if let Some(want) = q.has_children {
        let has = contract.model_has_children(&q.name, q.row)?;
        return Ok((has == want, json!(has)));
    }
    let (Some(values), Some(row)) = (&q.values, q.row) else {
        return Err(format!("the model query {} reads nothing", q.describe()));
    };
    let mut ok = true;
    let mut actual = Map::new();
    for (role, want) in values {
        let got = contract.model_data(&q.name, row, role)?;
        ok &= got == contract.resolve(want)?;
        actual.insert(role.clone(), got);
    }
    Ok((ok, one_or_all(actual)))
}

/// The value read for one name alone, or every name's as an object: how a
/// failed expectation over several members or roles reports what it read.
pub fn one_or_all(actual: Map<String, Value>) -> Value {
    match actual.len() {
        1 => actual.into_iter().next().map_or(Value::Null, |(_, v)| v),
        _ => Value::Object(actual),
    }
}
