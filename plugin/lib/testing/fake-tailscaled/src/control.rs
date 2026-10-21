//! The JSON-lines control protocol of the `fake-tailscaled` binary.
//!
//! Each stdin line is one command, `{"id": N, "cmd": "...", ...}`, and gets
//! one stdout line, `{"id": N, "ok": true, "result": ...}` or
//! `{"id": N, "ok": false, "error": "..."}`. Byte arguments and results use
//! [`crate::Bytes`]' encoding. There is no wait command: a client waits by
//! polling `requests` or `clients`.

use std::io::{BufRead, Write};

use serde_json::{json, Value};

use crate::bytes::{to_value, Bytes};
use crate::client::ClientReport;
use crate::request::Request;
use crate::script::Script;
use crate::server::Fake;

/// A request as the protocol reports it.
pub fn request_json(r: &Request) -> Value {
    json!({
        "client": r.client,
        "seq": r.seq,
        "method": r.method(),
        "target": r.target(),
        "unmatched": r.unmatched,
        "raw": to_value(&r.raw),
        "recorded": to_value(&r.recorded),
    })
}

/// A client report as the protocol reports it.
pub fn client_json(c: &ClientReport) -> Value {
    json!({
        "id": c.id,
        "connected": c.connected,
        "received": c.received,
        "written": c.written,
        "held": c.held,
        "parked": c.parked,
        "stream": c.stream,
    })
}

/// Reads commands from `input` until its end, answering each on `output`.
pub fn serve(fake: &Fake, input: impl BufRead, mut output: impl Write) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(cmd) => {
                let id = cmd.get("id").cloned().unwrap_or(Value::Null);
                match run(fake, &cmd) {
                    Ok(result) => json!({ "id": id, "ok": true, "result": result }),
                    Err(error) => json!({ "id": id, "ok": false, "error": error }),
                }
            }
            Err(e) => json!({ "id": null, "ok": false, "error": format!("not a JSON command: {e}") }),
        };
        writeln!(output, "{answer}")?;
        output.flush()?;
    }
    Ok(())
}

fn arg<T: serde::de::DeserializeOwned>(cmd: &Value, name: &str) -> Result<T, String> {
    let value = cmd.get(name).ok_or_else(|| format!("missing argument `{name}`"))?;
    serde_json::from_value(value.clone()).map_err(|e| format!("argument `{name}`: {e}"))
}

fn bytes(cmd: &Value, name: &str) -> Result<Vec<u8>, String> {
    arg::<Bytes>(cmd, name).map(|b| b.0)
}

/// Runs one command and returns its result.
fn run(fake: &Fake, cmd: &Value) -> Result<Value, String> {
    let name = cmd.get("cmd").and_then(Value::as_str).ok_or("missing `cmd`")?;
    Ok(match name {
        "requests" => json!(fake.requests().iter().map(request_json).collect::<Vec<_>>()),
        "clients" => json!(fake.clients().iter().map(client_json).collect::<Vec<_>>()),
        "connected" => json!(fake.connected_count()),
        "accepted" => json!(fake.accepted_total()),
        "held-count" => json!(fake.held_count()),
        "set-script" => {
            fake.set_script(arg::<Script>(cmd, "script")?)?;
            Value::Null
        }
        "push-line" => json!(fake.push_line(&bytes(cmd, "bytes")?)),
        "push-chunk" => json!(fake.push_chunk(&bytes(cmd, "bytes")?)),
        "push-to" => json!(fake.push_to(arg(cmd, "client")?, &bytes(cmd, "bytes")?)),
        "push-watch-line" => json!(fake.push_watch_line(&bytes(cmd, "bytes")?)),
        "hold-next" => {
            fake.hold_next(&bytes(cmd, "fragment")?);
            Value::Null
        }
        "complete-held" => json!(fake.complete_held(&bytes(cmd, "bytes")?)),
        "resume" => json!(fake.resume(&arg::<String>(cmd, "label")?)),
        "close-client" => json!(fake.close_client(arg(cmd, "client")?)),
        other => return Err(format!("unknown command `{other}`")),
    })
}
