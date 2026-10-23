//! The command line: its usage errors, `sites`, and `run` as far as the
//! sanity check of an unbuilt worker.

mod support;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use mutate_cpp::targets::TARGETS;
use support::{project, Dir, UNIT};

fn cli(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_mutate-cpp")).args(args).output().unwrap()
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

fn path(p: &Path) -> &str {
    p.to_str().unwrap()
}

#[test]
fn no_command_prints_the_usage() {
    let o = cli(&[]);
    assert_eq!(o.status.code(), Some(2));
    assert!(stderr(&o).contains("usage: mutate-cpp sites|run"), "{}", stderr(&o));
}

#[test]
fn sites_prints_one_json_line_per_site() {
    let d = Dir::new("cli-sites");
    let (tree, build) = (d.0.join("tree"), d.0.join("out"));
    project(&tree, &build, &[("a.cpp", UNIT)]);
    let o = cli(&["sites", "--build", path(&build), "--unit", path(&tree.join("a.cpp"))]);
    assert!(o.status.success(), "{}", stderr(&o));
    let lines: Vec<serde_json::Value> =
        String::from_utf8_lossy(&o.stdout).lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert!(lines.iter().any(|l| l["from"] == "==" && l["to"] == "!=" && l["line"] == 3), "{lines:?}");
    assert!(lines.iter().any(|l| l["kind"] == "DropCall"), "{lines:?}");
}

#[test]
fn run_names_what_it_lacks() {
    let o = cli(&["run"]);
    assert_eq!(o.status.code(), Some(2));
    assert!(stderr(&o).contains("--reference is required"), "{}", stderr(&o));
    let o = cli(&["run", "--reference", "r", "--work", "w", "--workers", "two"]);
    assert!(stderr(&o).contains("--workers:"), "{}", stderr(&o));
}

/// Every target, each a unit or a header its unit includes, with a
/// comparison to mutate.
fn targets() -> Vec<(String, String)> {
    TARGETS
        .iter()
        .map(|t| {
            let text = if t.file.ends_with(".h") {
                "inline bool header(int a) { return a < 2; }\n".to_string()
            } else if t.file == t.unit {
                let header = TARGETS.iter().find(|h| h.unit == t.file && h.file != t.file);
                let include = header.map_or(String::new(), |h| format!("#include \"{}\"\n", h.file));
                format!("{include}{UNIT}")
            } else {
                unreachable!("a target is a unit or a header")
            };
            (t.file.to_string(), text)
        })
        .collect()
}

#[test]
fn run_restores_each_worker_and_stops_at_an_unmutated_tree_that_fails() {
    let d = Dir::new("cli-run");
    let reference = d.0.join("reference");
    let files = targets();
    let borrowed: Vec<(&str, &str)> = files.iter().map(|(f, t)| (f.as_str(), t.as_str())).collect();
    project(&reference.join("tree"), &reference.join("out"), &borrowed);
    // The header is found from the tree's root, as the unit names it.
    let mut db: Vec<serde_json::Value> =
        serde_json::from_str(&fs::read_to_string(reference.join("out/compile_commands.json")).unwrap()).unwrap();
    for e in &mut db {
        e["arguments"].as_array_mut().unwrap().push(format!("-I{}", reference.join("tree").display()).into());
    }
    fs::write(reference.join("out/compile_commands.json"), serde_json::to_string(&db).unwrap()).unwrap();
    let w0 = d.0.join("work/w0");
    fs::create_dir_all(&w0).unwrap();
    assert!(Command::new("cp").arg("-a").arg(reference.join("tree")).arg(w0.join("tree")).status().unwrap().success());
    let left = &TARGETS[0].file;
    fs::write(w0.join("tree").join(left), "left mutated by a stopped run\n").unwrap();

    let record = d.0.join("record.json");
    let o = cli(&[
        "run",
        "--reference",
        path(&reference),
        "--work",
        path(&d.0.join("work")),
        "--workers",
        "1",
        "--record",
        path(&record),
        "--source",
        "abc",
        "--scenarios-bin",
        "true",
        "--corpus-bin",
        "true",
        "--only",
        "none",
    ]);
    let err = stderr(&o);
    assert_eq!(o.status.code(), Some(2), "{err}");
    for t in TARGETS {
        assert!(
            err.contains(&format!("{}: ", t.file)) && err.contains(" sites, "),
            "no site count for {}: {err}",
            t.file
        );
    }
    assert!(err.contains(&format!("restored {left}, left mutated by a stopped run")), "{err}");
    assert_eq!(fs::read_to_string(w0.join("tree").join(left)).unwrap(), text_of(left));
    assert!(err.contains("the unmutated tree in") && err.contains("does not pass"), "{err}");
    assert!(!record.exists(), "a run that never started wrote a record");
}

/// The text `targets()` gives `file`.
fn text_of(file: &str) -> String {
    targets().into_iter().find(|(f, _)| f == file).unwrap().1
}
