//! Check 7a: the Rust type ContractObject is the QML singleton `Contract`
//! (like QML_NAMED_ELEMENT). The QML assertions are in contract_named.qml.
use spike_tests::*;

fn main() {
    let app = headless_app();
    let mut r = Report::default();

    // The generated type description exports the C++ class under the QML name.
    let types = std::fs::read_to_string(staged_import_path().join("C7Spike/plugin.qmltypes")).unwrap();
    r.check(types.contains("name: \"ContractObject\""), "qmltypes describes the class ContractObject");
    r.check(types.contains("exports: [\"C7Spike/Contract 1.0\"]"), "qmltypes exports it as C7Spike/Contract");

    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_named.qml"));
    println!("outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), "contract_named.qml: all checks passed");
    drop(loaded);
    pump(&app, 1000);
    r.check(contract_threads() == 0, "backend thread gone after the engine (and the singleton) dropped");
    r.finish("check7a_named_singleton");
}
