//! The runner (plan decisions M4 to M6): applies one mutant to a worker's
//! copy of the tree, builds it, runs the kill suite's steps cheapest first
//! until one fails, restores the file, and records the outcome. Workers run
//! at once, one thread each, sharing the record.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;

use crate::record::{Entry, Outcome, Record};

/// A copy of the tree to mutate and its build directory, built once.
#[derive(Clone, Debug)]
pub struct Worker {
    pub tree: PathBuf,
    pub build: PathBuf,
}

/// One step of the kill suite: a command, `{tree}` and `{build}` standing
/// for the worker's, and how long it may run.
#[derive(Clone, Debug)]
pub struct Step {
    pub name: String,
    pub argv: Vec<String>,
    pub timeout_s: u64,
}

/// How a mutant is built and killed.
#[derive(Clone, Debug)]
pub struct Pipeline {
    pub build: Vec<String>,
    pub build_timeout_s: u64,
    pub steps: Vec<Step>,
}

/// One mutant: replace `from` at byte `offset` of `file`, relative to the
/// tree, with `to`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mutant {
    pub id: String,
    pub file: String,
    pub line: u32,
    pub col: u32,
    pub offset: usize,
    pub kind: String,
    pub from: String,
    pub to: String,
}

impl Mutant {
    fn entry(&self, outcome: Outcome) -> Entry {
        Entry {
            id: self.id.clone(),
            file: self.file.clone(),
            line: self.line,
            col: self.col,
            kind: self.kind.clone(),
            from: self.from.clone(),
            to: self.to.clone(),
            outcome,
            reason: None,
            killed_by_added: None,
        }
    }
}

/// What a command did.
enum Ran {
    Passed,
    Failed(String),
    TimedOut,
}

/// Runs `argv` with the worker's paths in it, under `timeout`, which kills
/// the command's whole process group when it runs out.
fn run(argv: &[String], w: &Worker, timeout_s: u64) -> Result<Ran, String> {
    let fill =
        |a: &String| a.replace("{tree}", &w.tree.to_string_lossy()).replace("{build}", &w.build.to_string_lossy());
    let args: Vec<String> = argv.iter().map(fill).collect();
    let out = Command::new("timeout")
        .args(["--kill-after=10", &timeout_s.to_string()])
        .args(&args)
        .output()
        .map_err(|e| format!("cannot run {args:?}: {e}"))?;
    match out.status.code() {
        Some(0) => Ok(Ran::Passed),
        Some(124) | Some(137) | None => Ok(Ran::TimedOut),
        Some(_) => {
            let text = String::from_utf8_lossy(&out.stdout).into_owned() + &String::from_utf8_lossy(&out.stderr);
            Ok(Ran::Failed(first_failure(&text)))
        }
    }
}

/// The line that says what failed: the harness's `FAIL ...`, ctest's
/// `(Failed)`, a compiler's `error:`, else the last line.
pub fn first_failure(text: &str) -> String {
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let marked = lines.iter().find(|l| l.starts_with("FAIL") || l.contains("(Failed)") || l.contains("error:"));
    let line = marked.or(lines.last()).copied().unwrap_or("");
    line.chars().take(300).collect()
}

/// Applies `m` in `w`, builds, runs the steps, and restores the file
/// whatever happened. A site whose text is not `from` is an error: the
/// sites are stale.
pub fn run_mutant(w: &Worker, m: &Mutant, p: &Pipeline) -> Result<Outcome, String> {
    let path = w.tree.join(&m.file);
    let original = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    if original.get(m.offset..m.offset + m.from.len()) != Some(m.from.as_str()) {
        return Err(format!("{}: no '{}' at byte {} ({}); the sites are stale", m.file, m.from, m.offset, m.id));
    }
    let mutated = format!("{}{}{}", &original[..m.offset], m.to, &original[m.offset + m.from.len()..]);
    std::fs::write(&path, mutated).map_err(|e| format!("{}: {e}", path.display()))?;
    let outcome = kill(w, p);
    std::fs::write(&path, &original).map_err(|e| format!("cannot restore {}: {e}", path.display()))?;
    outcome
}

fn kill(w: &Worker, p: &Pipeline) -> Result<Outcome, String> {
    match run(&p.build, w, p.build_timeout_s)? {
        Ran::Passed => {}
        Ran::Failed(detail) => return Ok(Outcome::BuildFailed { detail }),
        Ran::TimedOut => return Ok(Outcome::BuildFailed { detail: "the build timed out".into() }),
    }
    for step in &p.steps {
        match run(&step.argv, w, step.timeout_s)? {
            Ran::Passed => {}
            Ran::Failed(detail) => return confirm(w, step, detail),
            Ran::TimedOut => return Ok(Outcome::Timeout { step: step.name.clone() }),
        }
    }
    Ok(Outcome::Survived)
}

/// A failed step runs again: a kill counts only when it fails both times.
/// One that passes the second time is flaky, and an error: a kill under
/// load that a quiet run does not repeat says nothing about the mutant.
fn confirm(w: &Worker, step: &Step, detail: String) -> Result<Outcome, String> {
    match run(&step.argv, w, step.timeout_s)? {
        Ran::Passed => Err(format!("step {} is flaky: it failed once ({detail}) and then passed", step.name)),
        Ran::Failed(_) | Ran::TimedOut => Ok(Outcome::Killed { step: step.name.clone(), detail }),
    }
}

/// Copies each of `files` back into `w`'s tree from `reference` where they
/// differ, as a run stopped mid-mutant leaves one behind; returns those it
/// copied.
pub fn restore(w: &Worker, reference: &Path, files: &[&str]) -> Result<Vec<String>, String> {
    let mut copied = Vec::new();
    for f in files {
        let (from, to) = (reference.join(f), w.tree.join(f));
        let want = std::fs::read(&from).map_err(|e| format!("{}: {e}", from.display()))?;
        if std::fs::read(&to).ok().as_deref() != Some(want.as_slice()) {
            std::fs::write(&to, &want).map_err(|e| format!("{}: {e}", to.display()))?;
            copied.push(f.to_string());
        }
    }
    Ok(copied)
}

/// The unmutated tree in `w` builds and passes every step: the kill suite
/// is sound there, so a failure under a mutant is the mutant's.
pub fn sanity(w: &Worker, p: &Pipeline) -> Result<(), String> {
    match kill(w, p)? {
        Outcome::Survived => Ok(()),
        other => Err(format!("the unmutated tree in {} does not pass: {other:?}", w.tree.display())),
    }
}

/// Runs every mutant `record` lacks, one worker per thread, saving the
/// record at `path` after each. Returns how many ran; the first error stops
/// every worker.
pub fn run_all(
    workers: &[Worker],
    mutants: &[Mutant],
    p: &Pipeline,
    record: &mut Record,
    path: &Path,
) -> Result<usize, String> {
    let queue: VecDeque<&Mutant> = mutants.iter().filter(|m| !record.mutants.iter().any(|e| e.id == m.id)).collect();
    let ran = queue.len();
    let queue = Mutex::new(queue);
    let shared = Mutex::new((std::mem::replace(record, Record::new("", &[])), None::<String>));
    std::thread::scope(|s| {
        for w in workers {
            s.spawn(|| loop {
                if shared.lock().unwrap().1.is_some() {
                    return;
                }
                let Some(m) = queue.lock().unwrap().pop_front() else { return };
                let result = run_mutant(w, m, p);
                let mut guard = shared.lock().unwrap();
                match result {
                    Ok(outcome) => {
                        guard.0.mutants.push(m.entry(outcome));
                        if let Err(e) = guard.0.save(path) {
                            guard.1.get_or_insert(e);
                        }
                    }
                    Err(e) => {
                        guard.1.get_or_insert(e);
                    }
                }
            });
        }
    });
    let (done, error) = shared.into_inner().unwrap();
    *record = done;
    record.mutants.sort_by(|a, b| a.id.cmp(&b.id));
    record.save(path)?;
    error.map_or(Ok(ran), Err)
}
