//! Check 7e: two properties on one NOTIFY signal, and a signal the contract
//! derives from two inputs. All assertions are in contract_signals.qml.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_signals.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "contract_signals.qml: all checks passed");
    drop(loaded);
    r.finish("check7e_shared_notify");
}
