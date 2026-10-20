//! Check 7f: the singleton delegates to a backend chosen at construction from
//! C7SPIKE_CONTRACT_BACKEND (read in ContractRust::default; no C++). The same
//! contract_swap.qml runs once per backend, each in a fresh child process so
//! the env var is set before Qt or the plugin starts.
use spike_tests::*;

const ENV: &str = "C7SPIKE_CONTRACT_BACKEND";

fn main() {
    let Some(expected) = arg_value("expect-backend") else {
        let mut r = Report::default();
        r.check(respawn(&["--expect-backend=tokio"], &[(ENV, None)]), "env unset: real tokio backend, contract_swap.qml passed");
        r.check(respawn(&["--expect-backend=fake"], &[(ENV, Some("fake"))]), "env=fake: fake backend, contract_swap.qml passed");
        // Negative control: the QML must notice a wrong selection.
        r.check(!respawn(&["--expect-backend=fake"], &[(ENV, None)]), "a mismatched expectation fails (the QML check bites)");
        r.finish("check7f_backend_swap");
        return;
    };

    let app = headless_app();
    let mut r = Report::default();
    let loaded = load_and_wait(&app, &staged_import_path(), &qml_file("contract_swap.qml"));
    println!("[{expected}] outcome: {:?}", loaded.outcome);
    r.check(loaded.outcome == Outcome::Exited(0), format!("[{expected}] contract_swap.qml: all checks passed"));
    let want = usize::from(expected == "tokio");
    r.check(contract_threads() == want, format!("[{expected}] {want} backend thread(s) seen from Rust while alive"));
    drop(loaded);
    pump(&app, 1000);
    r.check(contract_threads() == 0, format!("[{expected}] no backend thread after drop"));
    r.finish(&format!("check7f_backend_swap [{expected}]"));
}
