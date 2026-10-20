//! Check 8: Qt loads the module through its PLUGIN ENTRY POINTS, not by luck.
//!
//! check1a cannot tell. Without `qt_plugin_instance` exported, QPluginLoader
//! fails ("Could not resolve 'qt_plugin_instance' function"), but dlopen has
//! already run the library's static initialisers, which register the types
//! and an embedded `:/qt/qml/C7Spike/qmldir`. QML then falls back to
//! "provided by linked library ... optional plugin not loaded" and the module
//! works anyway. This check fails that case. It requires:
//!   * `nm -D --defined-only` lists both entry points, and
//!   * Qt's import log says `module "C7Spike" provided by plugin`, with no
//!     "Could not resolve" line.
use spike_tests::*;

fn main() {
    if std::env::args().any(|a| a == "--child") {
        // The child: load the module once, with Qt's import/plugin logging on.
        let app = headless_app();
        let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("load.qml"));
        println!("child outcome: {:?}", loaded.outcome);
        std::process::exit(if loaded.outcome == Outcome::Exited(0) { 0 } else { 1 });
    }

    let mut r = Report::default();
    let so = staged_import_path().join("C7Spike/libC7Spike.so");
    let nm = std::process::Command::new("nm").args(["-D", "--defined-only"]).arg(&so).output().expect("run nm");
    let nm = String::from_utf8_lossy(&nm.stdout);
    for sym in ["qt_plugin_instance", "qt_plugin_query_metadata_v2"] {
        let line = nm.lines().find(|l| l.split_whitespace().last().is_some_and(|n| n.split('@').next() == Some(sym)));
        println!("nm -D: {}", line.unwrap_or("(missing)"));
        r.check(line.is_some_and(|l| l.contains(" T ")), format!("{sym} is a defined, exported function"));
    }

    let (ok, log) = respawn_output(
        &["--child"],
        &[("QT_LOGGING_RULES", "qt.qml.import=true;qt.core.plugin.loader=true")],
    );
    for l in log.lines().filter(|l| l.contains("C7Spike\" provided by") || l.contains("Could not resolve 'qt_plugin_instance'")) {
        println!("qt: {l}");
    }
    r.check(ok, "child loaded load.qml and its checks passed");
    r.check(log.contains("module \"C7Spike\" provided by plugin"), "Qt says: module \"C7Spike\" provided by plugin");
    r.check(!log.contains("Could not resolve 'qt_plugin_instance'"), "no \"Could not resolve 'qt_plugin_instance'\" fallback");
    r.check(!log.contains("module \"C7Spike\" provided by linked library"), "no \"C7Spike provided by linked library; optional plugin not loaded\" fallback");
    r.finish("check8_plugin_entry");
}
