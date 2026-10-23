//! A scenario that uses every kind needing no capability, and helpers that
//! load an edited copy and name what a rejection says.

use fake_tailscaled::scenario::Scenario;
use serde_json::{json, Value};

use super::TestDir;

/// A scenario that uses every step and expect kind that needs no
/// capability.
pub fn full() -> Value {
    json!({
        "format": 1,
        "id": "full",
        "requirements": ["R-HTTP-09"],
        "tag": "fix",
        "evidence": "harness-on-cpp",
        "clauses": ["every step and expect kind"],
        "deferred": ["nothing"],
        "needs": [],
        "fake": { "rules": [
            { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" }, "stream": { "framing": "chunked" } },
            { "match": { "method": "GET", "path": "/localapi/v0/status" }, "times": 1,
              "reply": { "status": 200, "body": { "json": { "BackendState": "Running" } },
                         "split": [{ "at": 10, "await": "rest" }] } },
            { "match": { "method": "PATCH", "target": "/localapi/v0/prefs" }, "hold": true }
        ] },
        "steps": [
            { "start": {} },
            { "call": { "name": "setAcceptRoutes", "args": [true] } },
            { "wait": { "contract": { "state": { "enum": "Running" } } } },
            { "wait": { "signal": { "name": "writeErrorChanged", "at_least": 1 } } },
            { "wait": { "fake": { "connected": 1 } } },
            { "wait": { "fake": { "recorded": { "method": "PATCH", "target": "/localapi/v0/prefs" }, "count": 1 } } },
            { "wait": { "fake": { "held": 1 } } },
            { "fake": { "push_line": "x" } },
            { "fake": { "push_chunk": { "hex": "ff" } } },
            { "fake": { "push_watch_line": "{}" } },
            { "fake": { "hold_next": "/status " } },
            { "fake": { "complete_held": { "status": 403, "body": "no" } } },
            { "fake": { "resume": "rest" } },
            { "fake": { "close_client": { "holding": "/localapi/v0/prefs" } } },
            { "fake": { "close_client": { "stream": true } } },
            { "fake": { "close_client": { "index": 2 } } },
            { "expect": { "id": "patch-sent", "precondition": true,
                          "requests": { "match": { "method": "PATCH", "path": "/localapi/v0/prefs" }, "count": 1 } } },
            { "expect": { "id": "error", "contract": { "writeError": "x" } } },
            { "expect": { "id": "expiry", "contract": { "keyExpiry": { "date": null } } } },
            { "expect": { "id": "expiry-set", "contract": { "keyExpiry": { "date": "2027-04-11T09:06:08.000Z" } } } },
            { "expect": { "id": "signal", "signal": { "name": "stateChanged", "count": 0 } } },
            { "expect": { "id": "bytes", "request": { "match": { "method": "GET", "target": "/localapi/v0/status" },
                                                      "raw": "GET /localapi/v0/status HTTP/1.1\r\n\r\n" } } }
        ],
        "on": {
            "cpp-286": { "result": "fail", "failing": [{ "id": "error", "actual": "y" }], "reason": "a defect" },
            "rust": { "result": "pass" }
        }
    })
}

/// A scenario that uses every capability step: it cannot run on either
/// implementation yet.
pub fn timed() -> Value {
    json!({
        "format": 1,
        "id": "timed",
        "requirements": ["R-CONN-13"],
        "tag": "fix",
        "evidence": "phase3-only",
        "clauses": ["the probe"],
        "needs": ["clock", "read-barrier", "idle-barrier", "retry-hook"],
        "fake": { "rules": [] },
        "steps": [
            { "start": {} },
            { "advance_ms": 30000 },
            { "barrier": "read" },
            { "barrier": "idle" },
            { "barrier": "retry" },
            { "expect": { "id": "state", "contract": { "state": { "enum": "NoState" } } } }
        ],
        "on": {
            "cpp-286": { "result": "cannot-run", "reason": "no clock" },
            "rust": { "result": "cannot-run", "reason": "Phase 3 adds the clock" }
        }
    })
}

/// Writes `value` as `<stem>.json` in `dir` and loads it.
pub fn load(dir: &TestDir, stem: &str, value: &Value) -> Result<Scenario, String> {
    let path = dir.join(format!("{stem}.json"));
    std::fs::write(&path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    Scenario::load(&path)
}

/// Loads `value` under its own id and returns the error.
pub fn rejected(value: Value) -> String {
    let dir = TestDir::new();
    let stem = value["id"].as_str().unwrap_or("x").to_string();
    match load(&dir, &stem, &value) {
        Ok(_) => panic!("accepted: {value}"),
        Err(e) => e,
    }
}

pub fn assert_names(error: &str, field: &str) {
    assert!(error.contains(field), "the error does not name `{field}`: {error}");
}

/// `full()` with `steps` appended.
pub fn with_steps(steps: Value) -> Value {
    let mut v = full();
    v["steps"].as_array_mut().unwrap().extend(steps.as_array().unwrap().iter().cloned());
    v
}
