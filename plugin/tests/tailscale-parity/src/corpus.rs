//! Runs the parser corpus (`tests/fixtures/tailscale/corpus/`): each case
//! is made into a scenario by `fake_tailscaled::corpus`, written into a
//! private directory, and run by [`runner::run_all`] like any scenario.

use std::path::{Path, PathBuf};

use fake_tailscaled::corpus::Case;
use fake_tailscaled::scenario::Implementation as Known;

use crate::child::PrivateRoot;
use crate::implementation::Implementation;
use crate::runner;

/// The scenarios a corpus made, in a private directory removed on drop.
pub struct Made {
    _root: PrivateRoot,
    /// Holds `<id>.json` for each case.
    pub dir: PathBuf,
    pub count: usize,
}

/// Loads every case in `dir` against `implementations` and writes the
/// scenario each makes. A corpus with no case is an error.
pub fn generate(dir: &Path, implementations: &[Known<'_>]) -> Result<Made, String> {
    let cases = Case::load_dir(dir, implementations)?;
    if cases.is_empty() {
        return Err(format!("no corpus cases found in {}", dir.display()));
    }
    let root = PrivateRoot::new();
    let out = root.path().join("scenarios");
    std::fs::create_dir(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    for case in &cases {
        let path = out.join(format!("{}.json", case.id));
        let text = serde_json::to_string_pretty(case.scenario_json()).expect("JSON serialises");
        std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    }
    Ok(Made { _root: root, dir: out, count: cases.len() })
}

/// Runs every case in `dir` (or those `filter` lists) `repeat` times
/// against `imp`, stopping at the first mismatch.
pub fn run_corpus(
    imp: &Implementation,
    implementations: &[Known<'_>],
    dir: &Path,
    repeat: u32,
    filter: Option<&str>,
) -> Result<String, String> {
    let made = generate(dir, implementations)?;
    let runner::Summary { count, implementation, repeat } =
        runner::run_all(imp, implementations, &made.dir, repeat, filter)?;
    Ok(format!("{count} corpus cases matched their declarations on {implementation} in {repeat} runs"))
}
