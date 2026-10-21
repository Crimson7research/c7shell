//! Runs every scenario under `tests/fixtures/tailscale/scenarios/` against
//! the implementation `C7_IMPL` names, each in its own isolated child.
//! `C7_SCENARIOS` filters by id; `C7_REPEAT` repeats the whole set.

use std::path::Path;

use tailscale_parity::child;
use tailscale_parity::implementation::Implementation;
use tailscale_parity::runner;

fn main() {
    if child::child_arg().as_deref() == Some("scenario") {
        std::process::exit(runner::child_main());
    }
    let imp = match Implementation::from_env() {
        Ok(imp) => imp,
        Err(e) => {
            println!("FAIL {e}");
            std::process::exit(1);
        }
    };
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/fixtures/tailscale/scenarios");
    let repeat = std::env::var("C7_REPEAT").ok().and_then(|r| r.parse().ok()).unwrap_or(1);
    let filter = std::env::var("C7_SCENARIOS").ok();
    match runner::run_all(&imp, fake_tailscaled::scenario::IMPLEMENTATIONS, &dir, repeat, filter.as_deref()) {
        Ok(summary) => println!("{summary}"),
        Err(e) => {
            println!("FAIL {e}");
            std::process::exit(1);
        }
    }
}
