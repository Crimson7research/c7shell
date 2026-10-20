//! Check 2: PeerModel keeps row identity across a reset-free update.
//! All assertions are in rows.qml; it exits with the number of failures.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("rows.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "rows.qml: all stable-row checks passed");
    drop(loaded);
    r.finish("check2_stable_rows");
}
