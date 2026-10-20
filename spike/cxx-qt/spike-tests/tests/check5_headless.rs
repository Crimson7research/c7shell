//! Check 5: the Rust test binary runs a Qt Quick scene headless.
use spike_tests::*;

fn main() {
    let app = headless_app(); // sets QT_QPA_PLATFORM=offscreen before Qt starts
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("headless.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "headless.qml rendered 2 frames and its checks passed");
    drop(loaded);
    r.finish("check5_headless");
}
