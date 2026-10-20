//! Check 7b: a Q_ENUM on the singleton, used as a NOTIFY property type.
//! All assertions are in contract_enum.qml; it exits with the number of failures.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_enum.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "contract_enum.qml: all checks passed");
    drop(loaded);
    r.finish("check7b_enum");
}
