//! Check 6: this Rust test binary loads the C++ #286 `C7` plugin (built by
//! CMake from the #286 tree, outside the spike), so Rust-driven QML tests can
//! run the same QML against the C++ implementation as a parity baseline.
//! It also loads `C7` and the Rust `C7Spike` into one engine.
//!
//! Skips (exit 0, with the reason printed) when C7_286_QML_DIR is unset.
use spike_tests::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn main() {
    let Some(c7_dir) = std::env::var_os("C7_286_QML_DIR").map(PathBuf::from) else {
        println!("check6_parity_286: SKIP: C7_286_QML_DIR is unset (point it at the #286 build's qml/ directory, the one containing C7/qmldir)");
        return;
    };

    // The same isolation #286's C7_TEST_MAIN applies (lib/testing/testmain.cpp):
    // TS_SOCKET names a path in a private directory that nothing listens on,
    // so LocalApiTailscaleBackend never opens the host's tailscaled socket.
    // Set before Qt (or any other thread) starts.
    let iso = workspace_dir().join("target/tmp").join(format!("check6-{}", std::process::id()));
    let _ = fs::remove_dir_all(&iso);
    fs::create_dir_all(&iso).unwrap();
    let sock = iso.join("no-such-tailscaled.sock");
    // SAFETY: first thing in main(), single-threaded.
    unsafe { std::env::set_var("TS_SOCKET", &sock) };

    let app = headless_app();
    let mut r = Report::default();

    r.check(c7_dir.join("C7/qmldir").is_file(), format!("{}/C7/qmldir exists", c7_dir.display()));
    r.check(!c7_dir.join("C7Spike").exists(), "the #286 qml dir does not provide C7Spike");
    let spike_dir = staged_import_path();
    r.check(!spike_dir.join("C7").exists(), "the spike's staged dir does not provide C7");
    r.check(!Path::new("/usr/lib/qt6/qml/C7").exists(), "no system-installed C7 can stand in");
    r.check(!sock.exists(), format!("TS_SOCKET {} does not exist", sock.display()));

    // Negative first, before C7 is ever loaded in this process: without the
    // #286 dir on the import path, `import C7` must fail.
    let missing = load_and_wait(&app, &spike_dir, &qml_file("parity286.qml"));
    println!("without C7_286_QML_DIR on the path: {:?}", missing.outcome);
    r.check(missing.outcome == Outcome::CreationFailed, "import C7 fails without the #286 dir");
    drop(missing);

    // 1. C7 alone: the contract singleton is readable and an action callable.
    let loaded = load_and_wait(&app, &c7_dir, &qml_file("parity286.qml"));
    println!("parity286.qml: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "C7.Tailscale read + setWantRunning outcome checks passed");
    let t = Instant::now();
    drop(loaded);
    let took = t.elapsed();
    println!("engine drop took {took:?}");
    r.check(took < Duration::from_secs(5), "engine with the C++ backend dropped without hanging");

    // 2. Both modules in one engine.
    let loaded = load_and_wait_paths(&app, &[&c7_dir, &spike_dir], &qml_file("both.qml"));
    println!("both.qml: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "one engine imports C7 (C++) and C7Spike (Rust) and drives both");
    drop(loaded);

    let _ = fs::remove_dir_all(&iso);
    r.finish("check6_parity_286");
}
