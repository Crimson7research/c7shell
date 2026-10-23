//! The parser corpus: one JSON file per case under
//! `tests/fixtures/tailscale/corpus/`, each pairing one `/status` body with
//! what the contract must publish from it. The format names no
//! implementation: the `tailscale-parity` harness turns each case into a
//! scenario (see [`Case::scenario`]) and runs it through QML, and Phase 3's
//! own tests read the same files.
//!
//! A case:
//!
//! - `format` (1), `id` (the file stem), `requirements`, `tag`, `clauses`,
//!   `deferred` and `on`, as a scenario has them. `tag` is the case's own:
//!   `fix` when what it expects differs from #286, so it fails there,
//!   `parity` when #286 already meets it, even for a clause of a `fix`
//!   requirement.
//! - `status`: the body, `{"file": path}` (under the fixture root, served
//!   unchanged) or `{"json": value}`, then `edits`, JSON Patch `add`,
//!   `replace` and `remove` operations applied to it. It must be an object
//!   with a `BackendState` naming one of [`STATES`], or nothing is
//!   published.
//! - `prefs`: the `/prefs` body, `captures/prefs.json` by default. Its
//!   `WantRunning` must be true: the runner waits for it.
//! - `suggest`: the `/suggest-exit-node` body, `{}` by default. A case that
//!   gives one expects a non-empty `recommendedExitNodeId`.
//! - `expect`: `contract`, member to value (as a scenario's values), and
//!   `peers` and `exitNodes`, the model's rows, all of them in order, each
//!   naming the roles it checks by name.
//!
//! The scenario answers the opening pass from the case, waits until
//! `wantRunning` reads true (the prefs half) and `state` reads the status's
//! `BackendState` (the status half, published with it, R-WATCH-11), so even
//! a case expecting only default values proves its status was published,
//! and until `recommendedExitNodeIdChanged` has fired
//! when the case gives a suggestion. It then expects each member
//! (`contract.<member>`), each model's row count (`<model>.count`) and each
//! row (`<model>[<i>]`): the ids a declared failure names.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::bytes::to_value;
use crate::scenario::files::read_under;
use crate::scenario::{role, Declaration, Implementation, Role, Scenario, Tag, IMPLEMENTATIONS};

mod edit;

pub use edit::{apply_edits, Edit, Op};

/// The watch request #286's opening pass makes.
pub const WATCH_TARGET: &str = "/localapi/v0/watch-ipn-bus?mask=18";

/// The `/prefs` body a case without `prefs` is served.
pub const DEFAULT_PREFS: &str = "captures/prefs.json";

/// The `BackendState` strings the contract's `state` has a value of the
/// same name for (#286's `TailscaleBackend::State`).
pub const STATES: [&str; 6] = ["NoState", "NeedsMachineAuth", "NeedsLogin", "Stopped", "Starting", "Running"];

/// The models a case can expect rows of.
pub const MODELS: [&str; 2] = ["peers", "exitNodes"];

/// One corpus case, loaded and turned into its scenario.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    pub format: u32,
    pub id: String,
    pub requirements: Vec<String>,
    pub tag: Tag,
    pub clauses: Vec<String>,
    #[serde(default)]
    pub deferred: Vec<String>,
    pub status: Value,
    #[serde(default)]
    pub edits: Vec<Edit>,
    pub prefs: Option<Value>,
    pub suggest: Option<Value>,
    pub expect: Expected,
    pub on: BTreeMap<String, Declaration>,
    #[serde(skip)]
    made: Option<(Value, Scenario)>,
}

/// What the contract publishes from the case's status.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Expected {
    #[serde(default)]
    pub contract: BTreeMap<String, Value>,
    pub peers: Option<Vec<BTreeMap<String, Value>>>,
    #[serde(rename = "exitNodes")]
    pub exit_nodes: Option<Vec<BTreeMap<String, Value>>>,
}

impl Case {
    /// Loads and validates `path` against the runner's implementations.
    pub fn load(path: &Path) -> Result<Case, String> {
        Case::load_for(path, IMPLEMENTATIONS)
    }

    /// Loads `path`, makes its scenario and validates that against
    /// `implementations`. Files are read under the fixture root, the
    /// parent of the case's directory.
    pub fn load_for(path: &Path, implementations: &[Implementation<'_>]) -> Result<Case, String> {
        let at = |e: String| format!("{}: {e}", path.display());
        let text = std::fs::read_to_string(path).map_err(|e| at(e.to_string()))?;
        let mut case: Case = serde_json::from_str(&text).map_err(|e| at(e.to_string()))?;
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let root = path.parent().and_then(Path::parent).ok_or_else(|| at("no fixture root above it".into()))?;
        let value = case.scenario_value(stem, root).map_err(at)?;
        let scenario: Scenario =
            serde_json::from_value(value.clone()).map_err(|e| at(format!("the scenario it makes: {e}")))?;
        scenario.validate(stem, implementations).map_err(at)?;
        case.made = Some((value, scenario));
        Ok(case)
    }

    /// Every case in `dir`, sorted by id.
    pub fn load_dir(dir: &Path, implementations: &[Implementation<'_>]) -> Result<Vec<Case>, String> {
        let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.retain(|p| p.extension().is_some_and(|e| e == "json"));
        paths.sort();
        paths.iter().map(|p| Case::load_for(p, implementations)).collect()
    }

    /// The scenario the case makes.
    pub fn scenario(&self) -> &Scenario {
        &self.made.as_ref().expect("a loaded case").1
    }

    /// The scenario the case makes, as a scenario file holds it: every body
    /// is inline, so it can be written anywhere.
    pub fn scenario_json(&self) -> &Value {
        &self.made.as_ref().expect("a loaded case").0
    }

    fn scenario_value(&self, stem: &str, root: &Path) -> Result<Value, String> {
        if self.format != 1 {
            return Err(format!("format: {} is not 1", self.format));
        }
        if self.id != stem {
            return Err(format!("id: `{}` differs from the file name `{stem}`", self.id));
        }
        let (status, state) = self.status_bytes(root).map_err(|e| format!("status: {e}"))?;
        let prefs = self.prefs.clone().unwrap_or_else(|| json!({ "file": DEFAULT_PREFS }));
        let prefs = body(&prefs, root).map_err(|e| format!("prefs: {e}"))?;
        let suggest = match &self.suggest {
            Some(b) => body(b, root).map_err(|e| format!("suggest: {e}"))?,
            None => b"{}".to_vec(),
        };
        let mut steps = vec![
            json!({ "start": {} }),
            json!({ "wait": { "contract": { "wantRunning": true, "state": { "enum": state } } } }),
        ];
        if self.suggest.is_some() {
            self.check_recommendation()?;
            steps.push(json!({ "wait": { "signal": { "name": "recommendedExitNodeIdChanged", "at_least": 1 } } }));
        }
        steps.extend(self.expect.steps()?);
        Ok(json!({
            "format": 1, "id": self.id, "requirements": self.requirements, "tag": self.tag,
            "evidence": "harness-on-cpp", "clauses": self.clauses, "deferred": self.deferred, "needs": [],
            "fake": { "rules": rules(&status, &prefs, &suggest) }, "steps": steps, "on": self.on,
        }))
    }

    /// The status body (the file unchanged, or the JSON with the edits) and
    /// its `BackendState`.
    fn status_bytes(&self, root: &Path) -> Result<(Vec<u8>, String), String> {
        let bytes = body(&self.status, root)?;
        let mut value: Value = serde_json::from_slice(&bytes).map_err(|e| format!("not JSON: {e}"))?;
        apply_edits(&mut value, &self.edits)?;
        let state = match value.get("BackendState").and_then(Value::as_str) {
            None | Some("") => {
                return Err("no non-empty BackendState string, so no snapshot is published (R-CONN-04)".into())
            }
            Some(s) if !STATES.contains(&s) => {
                return Err(format!(
                    "BackendState `{s}` is not one of {STATES:?}, so no state to wait for (R-WATCH-13)"
                ))
            }
            Some(s) => s.to_owned(),
        };
        let bytes = if self.edits.is_empty() { bytes } else { serde_json::to_vec(&value).expect("JSON serialises") };
        Ok((bytes, state))
    }

    fn check_recommendation(&self) -> Result<(), String> {
        match self.expect.contract.get("recommendedExitNodeId") {
            Some(Value::String(id)) if !id.is_empty() => Ok(()),
            _ => Err("suggest: the runner waits for recommendedExitNodeIdChanged, so expect.contract \
                      must give a non-empty recommendedExitNodeId"
                .into()),
        }
    }
}

impl Expected {
    /// One expect step per member, per model's row count and per row.
    fn steps(&self) -> Result<Vec<Value>, String> {
        let mut steps: Vec<Value> = self
            .contract
            .iter()
            .map(|(member, v)| json!({ "expect": { "id": format!("contract.{member}"), "contract": { member: v } } }))
            .collect();
        for (name, rows) in MODELS.iter().zip([&self.peers, &self.exit_nodes]) {
            let Some(rows) = rows else { continue };
            steps.push(
                json!({ "expect": { "id": format!("{name}.count"), "model": { "name": name, "count": rows.len() } } }),
            );
            for (i, row) in rows.iter().enumerate() {
                let id = format!("{name}[{i}]");
                if row.is_empty() {
                    return Err(format!("expect.{id}: empty; name at least one role"));
                }
                if let Some(key) = row.keys().find(|k| !matches!(role(k), Ok(Role::Name(_)))) {
                    return Err(format!("expect.{id}: `{key}` is not a role name"));
                }
                steps.push(json!({ "expect": { "id": id, "model": { "name": name, "row": i, "values": row } } }));
            }
        }
        if steps.is_empty() {
            return Err("expect: empty; give contract members or a model's rows".into());
        }
        Ok(steps)
    }
}

/// `{"file": path}` read under `root`, or `{"json": value}` serialised.
fn body(v: &Value, root: &Path) -> Result<Vec<u8>, String> {
    match v.as_object().filter(|o| o.len() == 1).and_then(|o| o.iter().next()) {
        Some((k, file)) if k == "file" => read_under(root, file),
        Some((k, value)) if k == "json" => Ok(serde_json::to_vec(value).expect("JSON serialises")),
        _ => Err(format!("{v} is not {{\"file\": path}} or {{\"json\": value}}")),
    }
}

/// The fake's rules: a watch stream and the three reads of a pass.
fn rules(status: &[u8], prefs: &[u8], suggest: &[u8]) -> Value {
    let reply = |target: &str, b: &[u8]| json!({ "match": { "method": "GET", "target": target }, "reply": { "status": 200, "body": to_value(b) } });
    json!([
        { "match": { "method": "GET", "target": WATCH_TARGET }, "stream": { "status": 200, "framing": "chunked" } },
        reply("/localapi/v0/status", status),
        reply("/localapi/v0/prefs", prefs),
        reply("/localapi/v0/suggest-exit-node", suggest),
    ])
}
