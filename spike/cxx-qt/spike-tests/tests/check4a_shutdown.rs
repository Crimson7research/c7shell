//! Check 4a: destroying the engine (and so the singleton) stops its tokio
//! runtime: no panic, no hang, no leaked thread, no late callback. Then 20
//! simulated Quickshell reloads in one process must not grow the thread count.
use spike_tests::*;
use std::time::{Duration, Instant};

const RELOADS: usize = 20;

fn main() {
    let app = headless_app();
    let mut r = Report::default();
    let path = staged_import_path();
    let before_any = thread_names().len();
    let mut totals = Vec::new();

    for i in 0..RELOADS {
        let loaded = load_and_wait(&app, &path, &qml_file("stress.qml"));
        let ok_load = loaded.outcome == Outcome::Exited(0);
        let during = tokio_threads();
        let t0 = Instant::now();
        drop(loaded); // engine -> Spike singleton -> SpikeRust::drop -> runtime shutdown
        let took = t0.elapsed();
        pump(&app, 1000); // deliver anything still posted
        let after = tokio_threads();
        let total = thread_names().len();
        totals.push(total);
        println!("reload {i:2}: load={ok_load} tokio threads during={during} after={after} drop took {took:?} total threads={total}");
        r.check(ok_load, format!("reload {i}: stress.qml loaded and got a callback"));
        r.check(during == 1, format!("reload {i}: one tokio worker while alive"));
        r.check(after == 0, format!("reload {i}: tokio threads gone after engine drop"));
        r.check(took < Duration::from_secs(5), format!("reload {i}: engine drop did not hang"));
    }
    println!("threads before first engine: {before_any}; after each reload: {totals:?}");
    r.check(totals.iter().all(|&t| t <= totals[0]), "thread count never grows past the first reload");

    let fin = load_and_wait(&app, &path, &qml_file("final.qml"));
    r.check(fin.outcome == Outcome::Exited(0), format!("final.qml counters check: {:?}", fin.outcome));
    drop(fin);
    pump(&app, 1000);
    r.check(tokio_threads() == 0, "no tokio thread left at the end");
    r.finish("check4a_shutdown");
}
