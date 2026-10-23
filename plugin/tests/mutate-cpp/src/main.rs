//! The mutation tool's command line.
//!
//! - `mutate-cpp sites --build DIR --unit FILE [--file FILE]` prints the
//!   sites of FILE (default: the unit) as JSON lines.
//! - `mutate-cpp run --reference DIR --work DIR --workers N --record FILE
//!   --source SHA --scenarios-bin FILE --corpus-bin FILE [--only ID,...]`
//!   runs every mutant of the targets the record lacks. `--reference` holds
//!   `tree/` and `out/` (build-reference.sh's cache for the commit); `--work`
//!   holds `w0` to `wN-1`, each a `tree/` copy and its built `out/`. Use
//!   `plugin/tests/mutate-cpp/run-baseline.sh`, which prepares them.

use std::path::{Path, PathBuf};

use mutate_cpp::record::Record;
use mutate_cpp::run::{restore, run_all, sanity, Mutant, Pipeline, Step, Worker};
use mutate_cpp::{query, targets};

fn arg(name: &str) -> Option<String> {
    let mut args = std::env::args().skip_while(|a| a != name);
    args.next()?;
    args.next()
}

fn required(name: &str) -> Result<String, String> {
    arg(name).ok_or_else(|| format!("{name} is required"))
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_default();
    let result = match cmd.as_str() {
        "sites" => sites(),
        "run" => run(),
        _ => Err("usage: mutate-cpp sites|run ... (see src/main.rs)".into()),
    };
    if let Err(e) = result {
        eprintln!("mutate-cpp: {e}");
        std::process::exit(2);
    }
}

fn sites() -> Result<(), String> {
    let build = PathBuf::from(required("--build")?);
    let unit = PathBuf::from(required("--unit")?);
    let file = arg("--file").map_or_else(|| unit.clone(), PathBuf::from);
    let (sites, skipped) = query::find(&build, &unit, &file)?;
    for s in &sites {
        let kind = format!("{:?}", s.kind);
        println!("{}", serde_json::json!({ "line": s.line, "col": s.col, "kind": kind, "from": s.from, "to": s.to }));
    }
    for s in &skipped {
        eprintln!("skipped: {s}");
    }
    Ok(())
}

/// Every target's mutants, from the reference build's view of its tree.
fn mutants(reference: &Path) -> Result<Vec<Mutant>, String> {
    let tree = reference.join("tree");
    let mut out = Vec::new();
    for t in targets::TARGETS {
        let (sites, skipped) = query::find(&reference.join("out"), &tree.join(t.unit), &tree.join(t.file))?;
        eprintln!("{}: {} sites, {} nodes skipped", t.file, sites.len(), skipped.len());
        for s in &sites {
            out.push(targets::mutant(&tree, s)?);
        }
    }
    Ok(out)
}

/// The kill suite (plan decision M4): #286's six Tailscale QtTest suites,
/// then the scenarios, then the corpus, each against the worker's build.
fn pipeline(scenarios: &str, corpus: &str) -> Pipeline {
    let harness = |bin: &str| -> Vec<String> {
        ["env", "-u", "C7_SCENARIOS", "-u", "C7_REPEAT", "C7_IMPL=cpp-286", "C7_QML_DIR={build}/qml", bin]
            .map(String::from)
            .to_vec()
    };
    let ctest = [
        "ctest",
        "--test-dir",
        "{build}",
        "-R",
        "^tst_(statusparser|peermodel|localapiclient|module|tailscalebackend|localapitailscalebackend)$",
        "--timeout",
        "120",
        "--output-on-failure",
        "--stop-on-failure",
    ];
    Pipeline {
        build: ["cmake", "--build", "{build}", "--parallel", "4"].map(String::from).to_vec(),
        build_timeout_s: 900,
        steps: vec![
            Step { name: "qttest".into(), argv: ctest.map(String::from).to_vec(), timeout_s: 600 },
            Step { name: "scenarios".into(), argv: harness(scenarios), timeout_s: 900 },
            Step { name: "corpus".into(), argv: harness(corpus), timeout_s: 600 },
        ],
    }
}

fn run() -> Result<(), String> {
    let reference = PathBuf::from(required("--reference")?);
    let work = PathBuf::from(required("--work")?);
    let count: usize = required("--workers")?.parse().map_err(|e| format!("--workers: {e}"))?;
    let path = PathBuf::from(required("--record")?);
    let p = pipeline(&required("--scenarios-bin")?, &required("--corpus-bin")?);
    let steps: Vec<String> = p.steps.iter().map(|s| s.name.clone()).collect();
    let mut record = Record::load_or_new(&path, &required("--source")?, &steps)?;
    let mut all = mutants(&reference)?;
    let mut rerun = Vec::new();
    if let Some(only) = arg("--only") {
        let wanted: Vec<&str> = only.split(',').collect();
        all.retain(|m| wanted.contains(&m.id.as_str()));
        (rerun, record.mutants) = record.mutants.into_iter().partition(|e| wanted.contains(&e.id.as_str()));
    }
    let workers: Vec<Worker> = (0..count)
        .map(|i| Worker { tree: work.join(format!("w{i}/tree")), build: work.join(format!("w{i}/out")) })
        .collect();
    let files: Vec<&str> = targets::TARGETS.iter().map(|t| t.file).collect();
    for w in &workers {
        for f in restore(w, &reference.join("tree"), &files)? {
            eprintln!("{}: restored {f}, left mutated by a stopped run", w.tree.display());
        }
        sanity(w, &p)?;
    }
    eprintln!("{} mutants, {} already recorded", all.len(), record.mutants.len());
    let ran = run_all(&workers, &all, &p, &mut record, &path)?;
    // A mutant run again keeps its reason or its added kill, where the new
    // outcome can carry it.
    record.carry(&rerun);
    record.save(&path)?;
    let s = record.summary();
    println!(
        "ran {ran}: {} mutants, {} killed, {} timeout, {} survived, {} build-failed, score {:.3}",
        s.mutants, s.killed, s.timeout, s.survived, s.build_failed, s.score
    );
    Ok(())
}
