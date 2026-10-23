//! The mutation record (plan decision M7): every mutant and its outcome,
//! with a summary and the score, saved as JSON after each mutant so a run
//! resumes where it stopped.

use std::path::Path;

use serde::{Deserialize, Serialize};

/// What the kill suite did with one mutant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "outcome")]
pub enum Outcome {
    /// A step failed; `detail` is its first failure line.
    Killed { step: String, detail: String },
    /// A step ran past its timeout: killed, counted apart.
    Timeout { step: String },
    /// Every step passed.
    Survived,
    /// The mutant did not build: no valid mutant, left out of the score.
    BuildFailed { detail: String },
}

/// One mutant and what became of it. (Its outcome is flattened into it,
/// which serde cannot combine with `deny_unknown_fields`.)
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    pub file: String,
    pub line: u32,
    pub col: u32,
    pub kind: String,
    pub from: String,
    pub to: String,
    #[serde(flatten)]
    pub outcome: Outcome,
    /// For a survivor: why no test can kill it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// For a survivor: the test added after the baseline that kills it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub killed_by_added: Option<String>,
}

/// The counts and the score: killed and timed-out mutants over every valid
/// one.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub mutants: usize,
    pub killed: usize,
    pub timeout: usize,
    pub survived: usize,
    pub build_failed: usize,
    pub score: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub format: u32,
    /// The commit whose C++ was mutated.
    pub source: String,
    /// The kill suite's steps, in the order they run.
    pub kill_suite: Vec<String>,
    pub summary: Summary,
    pub mutants: Vec<Entry>,
}

impl Record {
    pub fn new(source: &str, kill_suite: &[String]) -> Record {
        let mut r = Record {
            format: 1,
            source: source.to_string(),
            kill_suite: kill_suite.to_vec(),
            summary: Summary { mutants: 0, killed: 0, timeout: 0, survived: 0, build_failed: 0, score: 0.0 },
            mutants: Vec::new(),
        };
        r.summary = r.summary();
        r
    }

    /// The record at `path`, or a new one when there is none. A record of
    /// another source commit is an error: its mutants are not these.
    pub fn load_or_new(path: &Path, source: &str, kill_suite: &[String]) -> Result<Record, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Record::new(source, kill_suite)),
            Err(e) => return Err(format!("{}: {e}", path.display())),
        };
        let r: Record = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
        if r.source != source {
            return Err(format!("{} is a record of {}, not of {source}", path.display(), r.source));
        }
        Ok(r)
    }

    /// Writes the record with its summary recomputed, through a temporary
    /// file so a stopped run never leaves half a record.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        let mut r = self.clone();
        r.summary = r.summary();
        let text = serde_json::to_string_pretty(&r).map_err(|e| e.to_string())? + "\n";
        let tmp = path.with_extension("json.partial");
        std::fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn summary(&self) -> Summary {
        let count = |f: fn(&Outcome) -> bool| self.mutants.iter().filter(|m| f(&m.outcome)).count();
        let killed = count(|o| matches!(o, Outcome::Killed { .. }));
        let timeout = count(|o| matches!(o, Outcome::Timeout { .. }));
        let survived = count(|o| matches!(o, Outcome::Survived));
        let build_failed = count(|o| matches!(o, Outcome::BuildFailed { .. }));
        let valid = killed + timeout + survived;
        let score = if valid == 0 { 0.0 } else { (killed + timeout) as f64 / valid as f64 };
        Summary { mutants: self.mutants.len(), killed, timeout, survived, build_failed, score }
    }

    /// The ids of survivors with neither a reason nor a killing test.
    pub fn unaccounted(&self) -> Vec<&str> {
        let given = |s: &Option<String>| s.as_deref().is_some_and(|s| !s.trim().is_empty());
        self.mutants
            .iter()
            .filter(|m| m.outcome == Outcome::Survived && !given(&m.reason) && !given(&m.killed_by_added))
            .map(|m| m.id.as_str())
            .collect()
    }
}
