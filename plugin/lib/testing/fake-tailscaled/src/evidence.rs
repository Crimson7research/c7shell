//! The evidence classification, `tests/fixtures/tailscale/evidence.json`:
//! for every requirement, what shows it holds on #286 at a38dbca, and the
//! two markdown readers its checks compare it with (the requirement headings
//! and the traceability's Table B rows).
//!
//! The classes and the procedure are in
//! `docs/superpowers/plans/2026-10-21-phase2-harness.md`, "Evidence classes
//! and the classification rule".

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::Deserialize;

pub use crate::scenario::EvidenceClass;

/// What a clause can need that #286 at a38dbca does not offer: the
/// capabilities of `scenario::Capability`, a member listed under "Contract
/// additions", or an observable not reachable through QML at all.
pub const KNOWN_NEEDS: &[&str] =
    &["clock", "retry-hook", "idle-barrier", "read-barrier", "clock-hook", "added-member", "outside-module"];

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Evidence {
    pub format: u32,
    /// The #286 commit the classification is of.
    pub source: String,
    pub decided: String,
    /// How the procedure was applied, in prose.
    #[serde(default)]
    pub notes: Vec<String>,
    pub requirements: Vec<Entry>,
}

/// One requirement's classification.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub id: String,
    pub tag: String,
    pub class: EvidenceClass,
    /// harness-on-cpp: the Phase 2 PR whose scenarios run its clauses.
    pub pr: Option<u32>,
    /// harness-on-cpp: the clauses that run on a38dbca, in prose.
    pub runs: Option<String>,
    /// cpp-suite and phase3-only: what its clauses need.
    #[serde(default)]
    pub needs: Vec<String>,
    /// cpp-suite: every Table B row that maps it.
    #[serde(default)]
    pub tests: Vec<String>,
    /// phase3-only: why it cannot run on C++.
    pub reason: Option<String>,
    /// The clauses not run where the entry's class says, each with its own.
    #[serde(default)]
    pub deferred: Vec<Deferred>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Deferred {
    pub clause: String,
    pub class: EvidenceClass,
    #[serde(default)]
    pub needs: Vec<String>,
    #[serde(default)]
    pub tests: Vec<String>,
    pub reason: Option<String>,
    pub pr: Option<u32>,
}

impl Evidence {
    pub fn load(path: &Path) -> Result<Evidence, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }
}

/// The `### R-AREA-NN · tag · title` headings above "Contract additions",
/// as (id, tag), in order.
pub fn spec_headings(spec: &str) -> Vec<(String, String)> {
    spec.lines()
        .take_while(|l| !l.starts_with("## Contract additions"))
        .filter_map(|l| l.strip_prefix("### R-"))
        .filter_map(|rest| {
            let mut parts = rest.split(" · ");
            let id = parts.next()?;
            let tag = parts.next()?;
            Some((format!("R-{id}"), tag.trim().to_string()))
        })
        .collect()
}

/// Every Table B row, by the requirement ids its last cell names.
pub fn table_b(traceability: &str) -> BTreeMap<String, BTreeSet<String>> {
    table_b_section(traceability, "")
}

/// The Table B rows under the `###` file headings that contain `section`.
///
/// A row of a table headed `Test function` or `Function` (and not a
/// `Lines` table, which refines rows already listed) is `file::name`, the
/// backticked name in its first cell. A row of a table headed `Check` is
/// `file:line`, its second cell. Other tables, such as the helpers', add no
/// rows.
pub fn table_b_section(traceability: &str, section: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut rows: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut in_b = false;
    let mut file: Option<String> = None;
    let mut in_section = false;
    let mut header: Option<Vec<String>> = None;
    for line in traceability.lines() {
        if line.starts_with("## ") {
            in_b = line.starts_with("## Table B");
            continue;
        }
        if !in_b {
            continue;
        }
        if let Some(h) = line.strip_prefix("### ") {
            file = h.strip_prefix('`').and_then(|r| r.split('`').next()).map(str::to_string);
            in_section = h.contains(section);
            header = None;
            continue;
        }
        if !line.starts_with('|') {
            if line.trim().is_empty() {
                header = None;
            }
            continue;
        }
        let cells: Vec<String> = line.trim().trim_matches('|').split('|').map(|c| c.trim().to_string()).collect();
        let Some(head) = &header else {
            header = Some(cells);
            continue;
        };
        if cells.iter().all(|c| c.chars().all(|ch| matches!(ch, '-' | ':' | ' '))) {
            continue;
        }
        let (Some(file), true) = (&file, in_section) else { continue };
        let key = match head[0].as_str() {
            "Test function" | "Function" if head.get(1).is_none_or(|h| h != "Lines") => {
                let Some(name) = cells[0].strip_prefix('`').and_then(|r| r.split('`').next()) else { continue };
                format!("{file}::{name}")
            }
            "Check" => format!("{file}:{}", cells[1]),
            _ => continue,
        };
        for id in requirement_ids(cells.last().unwrap()) {
            rows.entry(id).or_default().insert(key.clone());
        }
    }
    rows
}

/// Every `R-AREA-NN` in `text`.
fn requirement_ids(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(at) = text[i..].find("R-") {
        let start = i + at;
        let mut j = start + 2;
        while j < bytes.len() && bytes[j].is_ascii_uppercase() {
            j += 1;
        }
        let digits = j + 1;
        if j > start + 2
            && bytes.get(j) == Some(&b'-')
            && bytes.len() >= digits + 2
            && bytes[digits..digits + 2].iter().all(u8::is_ascii_digit)
            && bytes.get(digits + 2).is_none_or(|b| !b.is_ascii_digit())
        {
            out.push(text[start..digits + 2].to_string());
            i = digits + 2;
        } else {
            i = start + 2;
        }
    }
    out
}

/// One row of the traceability's Table C: a requirement and the Phase 2
/// harness tests that run it on a38dbca.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HarnessRow {
    pub id: String,
    /// The evidence class, as evidence.json spells it.
    pub class: String,
    /// The ids of the scenarios that name it.
    pub scenarios: BTreeSet<String>,
    /// The ids of the corpus cases that name it.
    pub corpus: BTreeSet<String>,
    /// The ids of the view tests that name it.
    pub views: BTreeSet<String>,
}

/// The rows of the table headed `Requirement | Class | Scenarios | Corpus
/// cases | View tests | ...` under `## Table C`, in order. A test cell
/// lists backticked ids; a cell with none (`—`) is empty.
pub fn table_c(traceability: &str) -> Vec<HarnessRow> {
    let mut rows = Vec::new();
    let mut in_c = false;
    for line in traceability.lines() {
        if line.starts_with("## ") {
            in_c = line.starts_with("## Table C");
            continue;
        }
        if !in_c || !line.starts_with('|') {
            continue;
        }
        let cells: Vec<&str> = line.trim().trim_matches('|').split('|').map(str::trim).collect();
        let [id, class, scenarios, corpus, views, ..] = cells[..] else { continue };
        let ids = requirement_ids(id);
        if ids.len() != 1 {
            continue;
        }
        rows.push(HarnessRow {
            id: ids[0].clone(),
            class: backticked(class).into_iter().next().unwrap_or_default(),
            scenarios: backticked(scenarios),
            corpus: backticked(corpus),
            views: backticked(views),
        });
    }
    rows
}

/// Every backticked token in `cell`.
fn backticked(cell: &str) -> BTreeSet<String> {
    cell.split('`').skip(1).step_by(2).map(str::to_string).collect()
}
