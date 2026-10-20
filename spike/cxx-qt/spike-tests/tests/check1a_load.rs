//! Check 1a: a Cargo-built module directory (qmldir + qmltypes + one .so) is
//! loadable by a QQmlEngine given only that import path, and loading fails
//! when the directory is gone.
use spike_tests::*;
use std::fs;

fn main() {
    let app = headless_app();
    let mut r = Report::default();

    // The staged directory holds exactly qmldir, a .qmltypes file and one .so.
    let staged = staged_import_path().join("C7Spike");
    let mut names: Vec<String> =
        fs::read_dir(&staged).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
    names.sort();
    println!("staged {}: {names:?}", staged.display());
    r.check(names.len() == 3, "module dir has exactly 3 files");
    r.check(names.iter().any(|n| n == "qmldir"), "has qmldir");
    r.check(names.iter().filter(|n| n.ends_with(".qmltypes")).count() == 1, "has one .qmltypes");
    r.check(names.iter().filter(|n| n.ends_with(".so")).count() == 1, "has one .so");

    // Work on a private copy so removing it cannot disturb other checks.
    let root = workspace_dir().join("target/tmp").join(format!("check1a-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let copy = root.join("C7Spike");
    fs::create_dir_all(&copy).unwrap();
    for n in &names {
        fs::copy(staged.join(n), copy.join(n)).unwrap();
    }
    let qml = qml_file("load.qml");

    // Negative first (before the plugin is ever loaded into this process):
    // with the module directory removed, `import C7Spike` must fail.
    fs::remove_dir_all(&copy).unwrap();
    let missing = load_and_wait(&app, &root, &qml);
    println!("without module dir: {:?}", missing.outcome);
    r.check(missing.outcome == Outcome::CreationFailed, "load fails when the module dir is removed");
    drop(missing);

    // Positive: restore the directory; the same QML now loads and passes.
    fs::create_dir_all(&copy).unwrap();
    for n in &names {
        fs::copy(staged.join(n), copy.join(n)).unwrap();
    }
    let loaded = load_and_wait(&app, &root, &qml);
    println!("with module dir: {:?}", loaded.outcome);
    let paths = loaded.engine.import_path_list();
    let paths: Vec<String> = (0..paths.len()).map(|i| paths.get(i).unwrap().to_string()).collect();
    println!("engine import paths: {paths:?}");
    r.check(loaded.outcome == Outcome::Exited(0), "import C7Spike + singleton checks in QML passed");
    r.check(
        !paths.iter().any(|p| p != root.to_str().unwrap() && std::path::Path::new(p).join("C7Spike").exists()),
        "no other import path provides C7Spike",
    );
    drop(loaded);
    let _ = fs::remove_dir_all(&root);
    r.finish("check1a_load");
}
