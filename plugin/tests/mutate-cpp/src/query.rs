//! Runs `clang-query` on one source file with a build's compile commands,
//! once per mutation kind, and turns the dumps into sites.

use std::path::Path;
use std::process::Command;

use crate::sites::{self, Kind, Site};

/// Every kind, in the order they are queried.
pub const KINDS: &[Kind] = &[Kind::Binary, Kind::Integer, Kind::Bool, Kind::DropCall];

/// The sites in `file`, compiled as `build`'s `compile_commands.json` says,
/// or, for a header, as the translation unit `unit` that includes it.
pub fn find(build: &Path, unit: &Path, file: &Path) -> Result<(Vec<Site>, Vec<String>), String> {
    let source = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let name = file.to_str().ok_or("a non-UTF-8 path")?;
    let mut dumps = Vec::new();
    for kind in KINDS {
        dumps.push((*kind, run(build, unit, &kind.matcher(&anchored(name)))?));
    }
    let borrowed: Vec<(Kind, &str)> = dumps.iter().map(|(k, d)| (*k, d.as_str())).collect();
    Ok(sites::sites(name, &source, &borrowed))
}

/// A regex matching exactly `path`.
pub fn anchored(path: &str) -> String {
    let mut out = String::from("^");
    for c in path.chars() {
        if "\\.^$|?*+()[]{}".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('$');
    out
}

fn run(build: &Path, unit: &Path, matcher: &str) -> Result<String, String> {
    let out = Command::new("clang-query")
        .arg("-p")
        .arg(build)
        .arg(unit)
        .args(["-c", "set output dump", "-c", &format!("match {matcher}")])
        .output()
        .map_err(|e| format!("cannot run clang-query: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    if !out.status.success() || !stdout.contains(" match") {
        return Err(format!(
            "clang-query on {} exited with {}: {}",
            unit.display(),
            out.status,
            String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("")
        ));
    }
    Ok(stdout)
}
