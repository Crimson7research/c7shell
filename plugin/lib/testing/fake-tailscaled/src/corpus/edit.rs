//! Edits of a capture: the `add`, `replace` and `remove` operations of
//! JSON Patch (RFC 6902), each on a JSON Pointer (RFC 6901), so a corpus
//! case can say "the idle capture with its IPv6 address first" without a
//! second copy of the capture.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

/// One edit, applied in order.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Edit {
    pub op: Op,
    /// A JSON Pointer to the member or element, below the document.
    pub path: String,
    /// The new value, for `add` and `replace`; `null` is a value.
    #[serde(default, deserialize_with = "present")]
    pub value: Option<Value>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Op {
    /// Sets an object member, or inserts an array element (`-` appends).
    Add,
    /// Sets a member or element that exists.
    Replace,
    /// Removes a member or element that exists.
    Remove,
}

impl Op {
    fn name(self) -> &'static str {
        match self {
            Op::Add => "add",
            Op::Replace => "replace",
            Op::Remove => "remove",
        }
    }
}

/// A field that is present, `null` included.
fn present<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

/// Applies `edits` to `doc` in order. An error names the edit and its path.
pub fn apply_edits(doc: &mut Value, edits: &[Edit]) -> Result<(), String> {
    edits
        .iter()
        .enumerate()
        .try_for_each(|(i, e)| apply(doc, e).map_err(|m| format!("edits[{i}]: {} `{}`: {m}", e.op.name(), e.path)))
}

fn apply(doc: &mut Value, e: &Edit) -> Result<(), String> {
    let (parent, last) = e
        .path
        .rsplit_once('/')
        .filter(|_| e.path.starts_with('/'))
        .ok_or("the path must start with `/` and name a member or an element")?;
    let token = last.replace("~1", "/").replace("~0", "~");
    let value = || e.value.clone().ok_or_else(|| format!("{} needs a value", e.op.name()));
    match (doc.pointer_mut(parent).ok_or("its parent does not exist")?, e.op) {
        (Value::Object(map), Op::Remove) => map.remove(&token).map(drop).ok_or_else(|| "no such member".into()),
        (Value::Object(map), Op::Replace) if !map.contains_key(&token) => Err("no such member".into()),
        (Value::Object(map), _) => {
            map.insert(token, value()?);
            Ok(())
        }
        (Value::Array(items), op) => edit_array(items, &token, op, value),
        _ => Err("its parent is neither an object nor an array".into()),
    }
}

fn edit_array(
    items: &mut Vec<Value>,
    token: &str,
    op: Op,
    value: impl Fn() -> Result<Value, String>,
) -> Result<(), String> {
    let len = items.len();
    let index = match token {
        "-" if op == Op::Add => len,
        _ => token.parse::<usize>().map_err(|_| format!("`{token}` is not an array index"))?,
    };
    match op {
        Op::Add if index <= len => items.insert(index, value()?),
        Op::Replace if index < len => items[index] = value()?,
        Op::Remove if index < len => drop(items.remove(index)),
        _ => return Err(format!("index {index} is past the end of {len} elements")),
    }
    Ok(())
}
