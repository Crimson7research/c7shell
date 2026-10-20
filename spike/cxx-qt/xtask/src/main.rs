//! `cargo stage [--release]`: build the c7spike cdylib and lay it out the way a
//! system QML module is installed:
//!
//!   target/qml/C7Spike/qmldir
//!   target/qml/C7Spike/plugin.qmltypes
//!   target/qml/C7Spike/libC7Spike.so
//!
//! cxx-qt-build already writes qmldir and plugin.qmltypes to
//! target/cxxqt/qml_modules/C7Spike/; Cargo writes target/<profile>/libc7spike.so.
//! The qmldir says `plugin C7Spike`, so Qt looks for libC7Spike.so.
use std::path::{Path, PathBuf};
use std::process::{exit, Command};
use std::{env, fs};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) != Some("stage") {
        eprintln!("usage: cargo stage [--release]");
        exit(2);
    }
    let release = args.iter().any(|a| a == "--release");
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf();
    let target = env::var_os("CARGO_TARGET_DIR").map(PathBuf::from).unwrap_or(root.join("target"));

    let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let mut build = Command::new(cargo);
    build.current_dir(&root).args(["build", "-p", "c7spike", "--lib"]);
    if release {
        build.arg("--release");
    }
    if !build.status().expect("run cargo build").success() {
        exit(1);
    }

    let generated = target.join("cxxqt/qml_modules/C7Spike");
    let so = target.join(if release { "release" } else { "debug" }).join("libc7spike.so");
    let out = target.join("qml/C7Spike");
    let _ = fs::remove_dir_all(&out);
    fs::create_dir_all(&out).unwrap();
    for name in ["qmldir", "plugin.qmltypes"] {
        fs::copy(generated.join(name), out.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
    }
    fs::copy(&so, out.join("libC7Spike.so")).unwrap_or_else(|e| panic!("{}: {e}", so.display()));
    println!("{}", out.display());
}
