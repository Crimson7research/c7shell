//! Running a view test: each one in an isolated child that builds its
//! import tree under its private root, loads the view driver and runs the
//! body its header names. The parent compares the outcome with the header's
//! declaration, as the scenario runner does, and treats any line of the
//! child's log naming a `.qml` file as an error (plan decision V7).

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use fake_tailscaled::scenario::{Implementation as Known, IMPLEMENTATIONS};
use fake_tailscaled::views::ViewTest;
use serde_json::{json, Value};

use super::{tree, Body, Views};
use crate::child::{self, PrivateRoot};
use crate::runner::{arg, compare, outcome_from_json, outcome_json, Outcome, Report, RESULT_PREFIX};
use crate::{headless_app, load, qml_file};

/// The views a run is against: an implementation's name and the directory
/// holding its `quickshell/c7shell` views.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewImplementation {
    pub name: String,
    pub views: PathBuf,
}

const HOW: &str = "pass the last line of plugin/tests/tailscale-parity/build-reference.sh --views as C7_VIEWS_DIR";

/// The file a views directory must hold.
const POPOVER: &str = "Modules/Popovers/TailscalePopover.qml";

impl ViewImplementation {
    /// From `C7_IMPL` and `C7_VIEWS_DIR`.
    pub fn from_env() -> Result<ViewImplementation, String> {
        let name = std::env::var("C7_IMPL").ok();
        let dir = std::env::var("C7_VIEWS_DIR").ok();
        ViewImplementation::from_vars(name.as_deref(), dir.as_deref())
    }

    pub fn from_vars(name: Option<&str>, views: Option<&str>) -> Result<ViewImplementation, String> {
        let known: Vec<&str> = IMPLEMENTATIONS.iter().map(|(n, _)| *n).collect();
        let name = name.ok_or_else(|| format!("C7_IMPL is unset; name one of {known:?}"))?;
        if !known.contains(&name) {
            return Err(format!("C7_IMPL `{name}` is not one of {known:?}"));
        }
        let views = PathBuf::from(views.ok_or_else(|| format!("C7_VIEWS_DIR is unset; {HOW}"))?);
        if !views.join(POPOVER).is_file() {
            return Err(format!("{} holds no {POPOVER}; {HOW}", views.display()));
        }
        Ok(ViewImplementation { name: name.to_string(), views })
    }
}

/// The names of `bodies`.
pub fn names(bodies: &[(&'static str, Body)]) -> Vec<&'static str> {
    bodies.iter().map(|(n, _)| *n).collect()
}

/// Runs the view test whose header is at `path` against `imp`, in an
/// isolated child with `extra` variables.
pub fn run_one(
    imp: &ViewImplementation,
    implementations: &[Known<'_>],
    bodies: &[(&'static str, Body)],
    path: &Path,
    extra: &[(&str, &str)],
) -> Report {
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?").to_string();
    let root = PrivateRoot::new();
    let mut report = Report {
        id,
        outcome: Outcome::CannotRun,
        verdict: Ok(String::new()),
        root: root.path().to_path_buf(),
        log: String::new(),
        env: None,
        started: false,
    };
    let declaration = ViewTest::load_for(path, implementations, &names(bodies)).and_then(|t| {
        t.on.get(&imp.name).cloned().ok_or_else(|| format!("on.{}: no declaration for this implementation", imp.name))
    });
    match declaration {
        Err(e) => {
            report.outcome = Outcome::Error(e.clone());
            report.verdict = Err(format!("{}: error: {e}", imp.name));
        }
        Ok(declaration) => {
            report.started = true;
            (report.outcome, report.log, report.env) = run_child_of(imp, path, &root, extra);
            report.verdict = compare(&imp.name, &report.outcome, &declaration);
        }
    }
    drop(root);
    report
}

fn run_child_of(
    imp: &ViewImplementation,
    path: &Path,
    root: &PrivateRoot,
    extra: &[(&str, &str)],
) -> (Outcome, String, Option<BTreeMap<String, String>>) {
    let args = [
        "--child=view".to_string(),
        format!("--header={}", path.display()),
        format!("--views={}", imp.views.display()),
    ];
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let out = match child::isolated(&args, root, extra).output() {
        Ok(out) => out,
        Err(e) => return (Outcome::Error(format!("cannot start the child: {e}")), String::new(), None),
    };
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let log = stdout.clone() + &String::from_utf8_lossy(&out.stderr);
    let line = stdout.lines().rev().find_map(|l| l.strip_prefix(RESULT_PREFIX));
    let (outcome, env) = match line.map(serde_json::from_str::<Value>) {
        Some(Ok(v)) => (outcome_from_json(&v), serde_json::from_value(v["env"].clone()).ok()),
        Some(Err(e)) => (Outcome::Error(format!("a malformed result line: {e}")), None),
        None => (Outcome::Error(format!("no result line (the child exited with {})", out.status)), None),
    };
    (with_diagnostics(outcome, &log), log, env)
}

/// `outcome`, unless `log` has a line naming a `.qml` file: then an error
/// listing those lines. The child's result line is not a diagnostic,
/// whatever its values hold.
pub fn with_diagnostics(outcome: Outcome, log: &str) -> Outcome {
    let lines: Vec<&str> = log.lines().filter(|l| l.contains(".qml:") && !l.starts_with(RESULT_PREFIX)).collect();
    if lines.is_empty() {
        outcome
    } else {
        Outcome::Error(format!("QML diagnostics: {}", lines.join(" | ")))
    }
}

/// What [`run_all`] ran.
#[derive(Debug, PartialEq, Eq)]
pub struct Summary {
    pub count: usize,
    pub implementation: String,
    pub repeat: u32,
}

impl std::fmt::Display for Summary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Summary { count, implementation, repeat } = self;
        write!(f, "{count} view tests matched their declarations on {implementation} in {repeat} runs")
    }
}

/// Runs every header in `dir` (or those whose ids `filter` lists, comma
/// separated) `repeat` times, stopping at the first mismatch.
pub fn run_all(
    imp: &ViewImplementation,
    implementations: &[Known<'_>],
    bodies: &[(&'static str, Body)],
    dir: &Path,
    repeat: u32,
    filter: Option<&str>,
) -> Result<Summary, String> {
    let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|entries| entries.filter_map(|e| e.ok().map(|e| e.path())).collect())
        .unwrap_or_default();
    paths.retain(|p| p.extension().is_some_and(|e| e == "json"));
    let stem = |p: &PathBuf| p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
    if let Some(f) = filter {
        let wanted: Vec<&str> = f.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
        let stems: Vec<String> = paths.iter().map(stem).collect();
        let missing: Vec<&str> = wanted.iter().copied().filter(|id| !stems.iter().any(|s| s == id)).collect();
        if !missing.is_empty() {
            return Err(format!("no view test has the id {} in {}", missing.join(", "), dir.display()));
        }
        paths.retain(|p| wanted.contains(&stem(p).as_str()));
    }
    paths.sort();
    if paths.is_empty() {
        return Err(format!("no view tests found in {}", dir.display()));
    }
    let mut completed = 0;
    for run in 1..=repeat {
        for path in &paths {
            let r = run_one(imp, implementations, bodies, path, &[]);
            match &r.verdict {
                Ok(line) if run == 1 || repeat == 1 => println!("ok {} ({line})", r.id),
                Ok(_) => {}
                Err(e) => {
                    print!("{}", r.log);
                    println!("FAIL {} ({e})", r.id);
                    return Err(format!("run {run} of {repeat}: {}: {e}", r.id));
                }
            }
        }
        if repeat > 1 {
            println!("run {run} of {repeat}: every view test matched its declaration");
        }
        completed += 1;
    }
    Ok(Summary { count: paths.len(), implementation: imp.name.clone(), repeat: completed })
}

/// The child's main: build the tree, load the view driver, run the body,
/// print one result line.
pub fn child_main(bodies: &[(&'static str, Body)]) -> i32 {
    let env: BTreeMap<String, String> = std::env::vars().collect();
    let outcome = match (arg("header"), arg("views"), std::env::var_os("TMPDIR")) {
        (Some(header), Some(views), Some(tmp)) => {
            run_child(bodies, Path::new(&header), Path::new(&views), &Path::new(&tmp).join("views"))
        }
        _ => Outcome::Error("the child needs --header, --views and TMPDIR".into()),
    };
    let mut line = outcome_json(&outcome);
    line["env"] = json!(env);
    println!("{RESULT_PREFIX}{line}");
    let _ = std::io::stdout().flush();
    0
}

fn run_child(bodies: &[(&'static str, Body)], header: &Path, views: &Path, tree_dir: &Path) -> Outcome {
    if let Err(e) = crate::checked_max_iterations() {
        return Outcome::Error(e);
    }
    let test = match ViewTest::read(header) {
        Ok(t) => t,
        Err(e) => return Outcome::Error(e),
    };
    let Some((_, body)) = bodies.iter().find(|(n, _)| *n == test.body) else {
        return Outcome::Error(format!("body: no harness function is named `{}`", test.body));
    };
    if let Err(e) = tree::build(views, tree_dir) {
        return Outcome::Error(format!("the import tree: {e}"));
    }
    let app = headless_app();
    let loaded = match load(&app, tree_dir, &qml_file("views-driver.qml")) {
        Ok(l) => l,
        Err(e) => return Outcome::Error(e),
    };
    let mut v = Views { views: views.to_path_buf(), ..Views::new() };
    let result = body(&mut v);
    drop(loaded);
    match result {
        Err(e) => Outcome::Error(e),
        Ok(()) if v.failing.is_empty() => Outcome::Pass,
        Ok(()) => Outcome::Fail(v.failing),
    }
}
