//! Bodies read from files: a scenario's body may be `{"file": path}`, a
//! relative path under the fixture root, the parent of the directory that
//! holds the scenario (`tests/fixtures/tailscale/` for
//! `tests/fixtures/tailscale/scenarios/<id>.json`). The file's bytes become
//! the body unchanged, before the scenario is parsed.

use std::path::{Component, Path};

use serde_json::Value;

use crate::bytes::to_value;

/// Replaces every `{"file": path}` body in `scenario` (a rule's reply or
/// stream head, a `complete_held` step) with the file's bytes, read under
/// `root`. Returns whether it replaced any.
pub fn resolve_bodies(scenario: &mut Value, root: &Path) -> Result<bool, String> {
    let mut replaced = false;
    let rules = scenario.pointer_mut("/fake/rules").and_then(Value::as_array_mut);
    for (i, rule) in rules.into_iter().flatten().enumerate() {
        for kind in ["reply", "stream"] {
            let at = format!("fake.rules[{i}].{kind}.body");
            replaced |= resolve(rule.get_mut(kind), root).map_err(|e| format!("{at}.file: {e}"))?;
        }
    }
    let steps = scenario.get_mut("steps").and_then(Value::as_array_mut);
    for (i, step) in steps.into_iter().flatten().enumerate() {
        let at = format!("steps[{i}].fake.complete_held.body");
        replaced |= resolve(step.pointer_mut("/fake/complete_held"), root).map_err(|e| format!("{at}.file: {e}"))?;
    }
    Ok(replaced)
}

/// Replaces `reply.body` when it is `{"file": path}`.
fn resolve(reply: Option<&mut Value>, root: &Path) -> Result<bool, String> {
    let Some(body) = reply.and_then(|r| r.get_mut("body")) else { return Ok(false) };
    let Some(file) = body.as_object().filter(|o| o.len() == 1).and_then(|o| o.get("file")) else {
        return Ok(false);
    };
    *body = to_value(&read_under(root, file)?);
    Ok(true)
}

/// The bytes of `file`, a relative path under `root` without `..`.
pub(crate) fn read_under(root: &Path, file: &Value) -> Result<Vec<u8>, String> {
    let name = file.as_str().ok_or_else(|| format!("{file} is not a path"))?;
    let path = Path::new(name);
    if name.is_empty() || !path.components().all(|c| matches!(c, Component::Normal(_))) {
        return Err(format!("`{name}` must be a relative path under the fixture root, without `..`"));
    }
    let full = root.join(path);
    std::fs::read(&full).map_err(|e| format!("`{name}` ({}): {e}", full.display()))
}
