//! Check 7d: QDateTime and QStringList properties with NOTIFY, read in QML.
//! All assertions are in contract_types.qml; it exits with the number of failures.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_types.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "contract_types.qml: all checks passed");
    drop(loaded);
    r.finish("check7d_types");
}
