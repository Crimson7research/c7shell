//! `fake-tailscaled --socket PATH [--script FILE]`: a fake tailscaled for a
//! test that runs it out of process.
//!
//! It prints one event line, `{"event":"listening","path":"..."}` or
//! `{"event":"not-listening","reason":"..."}` (then exits 2), and then serves
//! the control protocol of `fake_tailscaled::control` on stdin and stdout.
//! At the end of stdin, which is the parent going away, it removes its
//! socket and exits 0.

use std::io::{self, Write};
use std::process::ExitCode;

use fake_tailscaled::{control, Fake, Script};
use serde_json::json;

const USAGE: &str = "usage: fake-tailscaled --socket PATH [--script FILE]";

struct Args {
    socket: String,
    script: Option<String>,
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Args, String> {
    let (mut socket, mut script) = (None, None);
    while let Some(flag) = args.next() {
        let slot = match flag.as_str() {
            "--socket" => &mut socket,
            "--script" => &mut script,
            other => return Err(format!("unknown argument {other}")),
        };
        *slot = Some(args.next().ok_or(format!("{flag} needs a value"))?);
    }
    Ok(Args { socket: socket.ok_or("--socket is required")?, script })
}

fn load_script(path: &str) -> Result<Script, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))
}

fn event(value: serde_json::Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn main() -> ExitCode {
    let args = match parse(std::env::args().skip(1)) {
        Ok(args) => args,
        Err(e) => {
            eprintln!("fake-tailscaled: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let fake = Fake::start(&args.socket);
    if let Some(reason) = fake.error() {
        event(json!({ "event": "not-listening", "reason": reason }));
        return ExitCode::from(2);
    }
    if let Some(path) = &args.script {
        if let Err(reason) = load_script(path).and_then(|s| fake.set_script(s)) {
            drop(fake);
            event(json!({ "event": "not-listening", "reason": reason }));
            return ExitCode::from(2);
        }
    }
    event(json!({ "event": "listening", "path": args.socket }));
    let served = control::serve(&fake, io::stdin().lock(), io::stdout().lock());
    drop(fake);
    match served {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("fake-tailscaled: {e}");
            ExitCode::FAILURE
        }
    }
}
