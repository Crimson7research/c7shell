//! Check 7c, lifetime: the singleton's owned models are destroyed with it,
//! exactly once, across 20 simulated Quickshell reloads in one process (the
//! round-1 check 4a loop). The process re-runs itself with
//! `--expect-created=N` so the final QML can assert the exact count.
use spike_tests::*;
use std::time::{Duration, Instant};

const RELOADS: usize = 20;
const MODELS_PER_SINGLETON: usize = 2;

fn main() {
    let Some(expected) = arg_value("expect-created") else {
        let expected = format!("--expect-created={}", MODELS_PER_SINGLETON * (RELOADS + 1));
        let ok = respawn(&[&expected], &[("C7SPIKE_CONTRACT_BACKEND", None)]);
        let mut r = Report::default();
        r.check(ok, "child run (20 reloads + final counters) passed");
        r.finish("check7c_lifetime");
        return;
    };
    println!("expecting {expected} PeerModels created in total");

    let app = headless_app();
    let mut r = Report::default();
    let path = staged_import_path();
    let mut totals = Vec::new();

    for i in 0..RELOADS {
        let loaded = load_and_wait(&app, &path, &qml_file("contract_reload.qml"));
        let ok_load = loaded.outcome == Outcome::Exited(0);
        let during = contract_threads();
        let t0 = Instant::now();
        drop(loaded); // engine -> Contract singleton -> ContractRust drop -> models + runtime
        let took = t0.elapsed();
        pump(&app, 1000);
        let after = contract_threads();
        let total = thread_names().len();
        totals.push(total);
        println!("reload {i:2}: load={ok_load} backend threads during={during} after={after} drop took {took:?} total threads={total}");
        r.check(ok_load, format!("reload {i}: views bound to the owned models, a tokio update arrived"));
        r.check(during == 1, format!("reload {i}: one backend thread while alive"));
        r.check(after == 0, format!("reload {i}: backend thread gone after engine drop"));
        r.check(took < Duration::from_secs(5), format!("reload {i}: engine drop did not hang"));
    }
    r.check(totals.iter().all(|&t| t <= totals[0]), format!("thread count never grows past the first reload: {totals:?}"));

    let fin = load_and_wait(&app, &path, &qml_file("contract_final.qml"));
    r.check(fin.outcome == Outcome::Exited(0), format!("contract_final.qml counters check: {:?}", fin.outcome));
    drop(fin);
    pump(&app, 1000);
    r.check(contract_threads() == 0, "no backend thread left at the end");
    r.finish("check7c_lifetime (child)");
}
