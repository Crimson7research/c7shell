//! The view test header: one JSON file per view test under
//! `tests/fixtures/tailscale/views/`. The header says what the test runs and
//! what each implementation is declared to do; its body is a Rust function
//! in the `tailscale-parity` harness, named by `body`, that drives #286's
//! views over the QML stand-in. See
//! `docs/superpowers/plans/2026-10-22-phase2-309.md`, decision V1.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::Deserialize;

use crate::scenario::{
    is_requirement_id, validate_declarations, Declaration, Declared, EvidenceClass, Implementation, Tag,
    IMPLEMENTATIONS,
};

/// One view test's header.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ViewTest {
    pub format: u32,
    pub id: String,
    pub requirements: Vec<String>,
    pub tag: Tag,
    pub evidence: EvidenceClass,
    /// The acceptance clauses it runs, in prose.
    pub clauses: Vec<String>,
    /// The clauses of its requirements it does not run, and where they are.
    #[serde(default)]
    pub deferred: Vec<String>,
    /// The harness function that runs it.
    pub body: String,
    /// What each implementation is declared to do.
    pub on: BTreeMap<String, Declaration>,
}

impl ViewTest {
    /// Loads and validates `path` against the runner's implementations and
    /// the harness's `bodies`.
    pub fn load(path: &Path, bodies: &[&str]) -> Result<ViewTest, String> {
        ViewTest::load_for(path, IMPLEMENTATIONS, bodies)
    }

    /// Loads and validates `path` against `implementations` and `bodies`.
    pub fn load_for(path: &Path, implementations: &[Implementation<'_>], bodies: &[&str]) -> Result<ViewTest, String> {
        let test = ViewTest::read(path)?;
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        test.validate(stem, implementations, bodies).map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(test)
    }

    /// Parses `path` without validating it.
    pub fn read(path: &Path) -> Result<ViewTest, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Every check the header makes, for a file named `stem`.
    pub fn validate(&self, stem: &str, implementations: &[Implementation<'_>], bodies: &[&str]) -> Result<(), String> {
        if self.format != 1 {
            return Err(format!("format: {} is not 1", self.format));
        }
        if self.id != stem {
            return Err(format!("id: `{}` differs from the file name `{stem}`", self.id));
        }
        if self.requirements.is_empty() {
            return Err("requirements: empty".into());
        }
        if let Some(bad) = self.requirements.iter().find(|r| !is_requirement_id(r)) {
            return Err(format!("requirements: `{bad}` is not an R-AREA-NN id"));
        }
        if self.clauses.is_empty() {
            return Err("clauses: empty; say which acceptance clauses this view test runs".into());
        }
        if self.evidence != EvidenceClass::HarnessOnCpp {
            return Err(format!(
                "evidence: a view test runs on #286, so it is harness-on-cpp, not {:?}",
                self.evidence
            ));
        }
        if !bodies.contains(&self.body.as_str()) {
            return Err(format!("body: no harness function is named `{}`", self.body));
        }
        let needs = BTreeSet::new();
        let declared = Declared { tag: self.tag, needs: &needs, on: &self.on };
        // The body's check ids are in Rust; the runner compares them.
        validate_declarations(&declared, implementations, &|_| Ok(()))
    }
}
