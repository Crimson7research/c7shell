//! Check 7c: the singleton owns a CONSTANT model property, and a ListView bound
//! to it keeps stable rows through updates from tokio.
//! All assertions are in contract_model.qml; it exits with the number of failures.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_model.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "contract_model.qml: all checks passed");
    drop(loaded);
    pump(&app, 1000);
    r.check(contract_threads() == 0, "backend thread gone after the engine (and the singleton) dropped");
    r.finish("check7c_owned_model");
}
