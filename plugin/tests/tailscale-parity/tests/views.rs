//! Runs every view test under `tests/fixtures/tailscale/views/` against the
//! views `C7_VIEWS_DIR` names, as implementation `C7_IMPL`, each in its own
//! isolated child. `C7_SCENARIOS` filters by id; `C7_REPEAT` repeats the
//! whole set. Every body is named by a header first.

use std::path::Path;

use fake_tailscaled::scenario::IMPLEMENTATIONS;
use fake_tailscaled::views::ViewTest;
use tailscale_parity::views::{bodies, run};
use tailscale_parity::{child, runner};

fn fail(e: &str, code: i32) -> ! {
    println!("FAIL {e}");
    std::process::exit(code);
}

fn main() {
    if child::child_arg().as_deref() == Some("view") {
        std::process::exit(run::child_main(bodies::ALL));
    }
    let imp = run::ViewImplementation::from_env().unwrap_or_else(|e| fail(&e, 1));
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/fixtures/tailscale/views");
    let paths = run::headers(&dir).unwrap_or_else(|e| fail(&e, 1));
    let named: Vec<String> =
        paths.iter().map(|p| ViewTest::read(p).map(|t| t.body).unwrap_or_else(|e| fail(&e, 1))).collect();
    let unused: Vec<&str> = run::names(bodies::ALL).into_iter().filter(|b| !named.iter().any(|n| n == b)).collect();
    if !unused.is_empty() {
        fail(&format!("no view test header names the bodies {unused:?}"), 1);
    }
    let repeat = runner::parse_repeat(std::env::var("C7_REPEAT").ok().as_deref()).unwrap_or_else(|e| fail(&e, 2));
    let filter = std::env::var("C7_SCENARIOS").ok();
    match run::run_all(&imp, IMPLEMENTATIONS, bodies::ALL, &dir, repeat, filter.as_deref()) {
        Ok(summary) => println!("{summary}"),
        Err(e) => fail(&e, 1),
    }
}
