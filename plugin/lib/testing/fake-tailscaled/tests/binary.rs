//! The standalone `fake-tailscaled` binary: started on a socket, driven by
//! JSON lines on stdin, answered on stdout, stopped by the end of stdin.

mod support;

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::time::Instant;

use fake_tailscaled::{control, Fake, Script, FAILURE_BOUND};
use serde_json::{json, Value};
use support::{Client, TestDir};

const BIN: &str = env!("CARGO_BIN_EXE_fake-tailscaled");

/// The binary, with its stdout read line by line on a thread so that every
/// read is bounded.
struct Bin {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    next_id: u64,
}

impl Bin {
    fn start(args: &[&str]) -> Bin {
        let mut child = Command::new(BIN)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn fake-tailscaled");
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if tx.send(line).is_err() {
                    return;
                }
            }
        });
        let stdin = child.stdin.take();
        Bin { child, stdin, lines, next_id: 1 }
    }

    fn line(&self) -> Value {
        let line = self.lines.recv_timeout(FAILURE_BOUND).expect("a line from fake-tailscaled");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"))
    }

    fn send_raw(&mut self, line: &str) -> Value {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{line}").unwrap();
        stdin.flush().unwrap();
        self.line()
    }

    /// Sends one command and returns its answer, checking its id.
    fn send(&mut self, mut cmd: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        cmd["id"] = json!(id);
        let answer = self.send_raw(&cmd.to_string());
        assert_eq!(answer["id"], json!(id), "{answer}");
        answer
    }

    /// Sends one command that must succeed and returns its result.
    fn ok(&mut self, cmd: Value) -> Value {
        let answer = self.send(cmd.clone());
        assert_eq!(answer["ok"], json!(true), "{cmd} failed: {answer}");
        answer["result"].clone()
    }

    /// Polls `cmd` until `done(result)`, within FAILURE_BOUND.
    fn poll(&mut self, cmd: Value, mut done: impl FnMut(&Value) -> bool) -> Value {
        let deadline = Instant::now() + FAILURE_BOUND;
        loop {
            let result = self.ok(cmd.clone());
            if done(&result) {
                return result;
            }
            assert!(Instant::now() < deadline, "{cmd} never reached the expected result; last {result}");
        }
    }

    /// Closes stdin and waits for the exit.
    fn finish(mut self) -> ExitStatus {
        drop(self.stdin.take());
        let deadline = Instant::now() + FAILURE_BOUND;
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(Instant::now() < deadline, "fake-tailscaled did not exit after end of stdin");
            std::thread::yield_now();
        }
    }
}

impl Drop for Bin {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn get(path: &str) -> Vec<u8> {
    format!("GET {path} HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n").into_bytes()
}

fn rules() -> Value {
    json!({ "rules": [
        { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" }, "stream": { "framing": "chunked" } },
        { "match": { "method": "GET", "path": "/r" }, "reply": { "body": "r" } },
        { "match": { "method": "GET", "path": "/h" }, "hold": true },
        { "match": { "method": "GET", "path": "/s" }, "reply": { "body": "split", "split": [{ "at": 3, "await": "go" }] } },
        { "match": { "method": "GET", "path": "/k" }, "reply": { "body": "k", "then": "keep-open" } }
    ] })
}

#[test]
fn it_announces_where_it_listens() {
    let dir = TestDir::new();
    let path = dir.socket();
    let bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    assert_eq!(bin.line(), json!({ "event": "listening", "path": path.to_str().unwrap() }));
    assert!(path.exists());
    assert!(bin.finish().success());
}

#[test]
fn it_refuses_a_taken_path_and_exits_2() {
    let dir = TestDir::new();
    let path = dir.socket();
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, b"x").unwrap();
    let bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    let event = bin.line();
    assert_eq!(event["event"], json!("not-listening"));
    assert!(event["reason"].as_str().unwrap().contains("already exists"), "{event}");
    assert_eq!(bin.finish().code(), Some(2));
    assert_eq!(std::fs::read(&path).unwrap(), b"x");
}

#[test]
fn it_exits_2_without_a_socket_argument() {
    for args in [vec![], vec!["--socket"], vec!["--nope", "x"]] {
        let status = Command::new(BIN)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(2), "{args:?}");
    }
}

#[test]
fn it_loads_a_script_file() {
    let dir = TestDir::new();
    let script = dir.join("script.json");
    std::fs::write(&script, rules().to_string()).unwrap();
    let path = dir.socket();
    let mut bin = Bin::start(&["--socket", path.to_str().unwrap(), "--script", script.to_str().unwrap()]);
    assert_eq!(bin.line()["event"], json!("listening"));
    let mut client = Client::connect(&path);
    client.write(&get("/r"));
    assert_eq!(client.read_until_closed(), b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nr");
    assert_eq!(bin.ok(json!({ "cmd": "accepted" })), json!(1));
    assert!(bin.finish().success());
}

#[test]
fn it_refuses_a_script_file_it_cannot_load() {
    let dir = TestDir::new();
    let script = dir.join("script.json");
    std::fs::write(&script, "{\"rules\": [{}]}").unwrap();
    let path = dir.socket();
    let bin = Bin::start(&["--socket", path.to_str().unwrap(), "--script", script.to_str().unwrap()]);
    assert_eq!(bin.line()["event"], json!("not-listening"));
    assert_eq!(bin.finish().code(), Some(2));
    assert!(!path.exists(), "the socket outlived a refused start");
}

const WATCH_HEAD: &[u8] = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";

/// A watch stream, and each push command reaching it. Returns the stream,
/// client 1, which must stay open.
fn every_push(bin: &mut Bin, path: &std::path::Path) -> Client {
    let mut watch = Client::connect(path);
    watch.write(&get("/localapi/v0/watch-ipn-bus?mask=18"));
    watch.read_exactly(WATCH_HEAD.len());
    assert_eq!(bin.ok(json!({ "cmd": "connected" })), json!(1));
    assert_eq!(bin.ok(json!({ "cmd": "push-watch-line", "bytes": "{}" })), json!(1));
    let head = WATCH_HEAD.len();
    assert_eq!(&watch.read_exactly(head + 8)[head..], b"3\r\n{}\n\r\n");
    assert_eq!(bin.ok(json!({ "cmd": "push-line", "bytes": "l" })), json!(1));
    assert_eq!(bin.ok(json!({ "cmd": "push-chunk", "bytes": { "hex": "ff" } })), json!(1));
    assert_eq!(bin.ok(json!({ "cmd": "push-to", "client": 1, "bytes": "t" })), json!(true));
    assert_eq!(&watch.read_exactly(head + 8 + 4)[head + 8..], b"l\n\xfft");
    watch
}

/// A held request completed (client 2), and a hold armed by command and
/// closed (client 3).
fn every_hold(bin: &mut Bin, path: &std::path::Path) {
    let mut held = Client::connect(path);
    held.write(&get("/h"));
    bin.poll(json!({ "cmd": "held-count" }), |r| r == &json!(1));
    assert_eq!(bin.ok(json!({ "cmd": "complete-held", "bytes": "done" })), json!(1));
    assert_eq!(held.read_until_closed(), b"done");

    assert_eq!(bin.ok(json!({ "cmd": "hold-next", "fragment": "/r " })), Value::Null);
    let mut armed = Client::connect(path);
    armed.write(&get("/r"));
    bin.poll(json!({ "cmd": "held-count" }), |r| r == &json!(1));
    assert_eq!(bin.ok(json!({ "cmd": "close-client", "client": 3 })), json!(true));
    assert_eq!(armed.read_until_closed(), b"");
    assert_eq!(bin.ok(json!({ "cmd": "close-client", "client": 3 })), json!(false));
}

/// A split reply, resumed (client 4).
fn a_resume(bin: &mut Bin, path: &std::path::Path) {
    let mut split = Client::connect(path);
    split.write(&get("/s"));
    assert_eq!(split.read_exactly(3), b"HTT");
    bin.poll(json!({ "cmd": "clients" }), |r| r[3]["parked"] == json!(true));
    assert_eq!(bin.ok(json!({ "cmd": "resume", "label": "go" })), json!(1));
    assert!(split.read_until_closed().ends_with(b"\r\n\r\nsplit"));
}

/// The reports after every_push, every_hold and a_resume.
fn the_reports(bin: &mut Bin) {
    let clients = bin.poll(json!({ "cmd": "clients" }), |r| r[3]["connected"] == json!(false));
    assert_eq!(
        clients[0],
        json!({ "id": 1, "connected": true, "received": 80, "written": 59, "held": false, "parked": false, "stream": true })
    );
    assert_eq!(bin.ok(json!({ "cmd": "accepted" })), json!(4));
    let requests = bin.ok(json!({ "cmd": "requests" }));
    assert_eq!(requests.as_array().unwrap().len(), 4);
    assert_eq!(
        requests[1],
        json!({ "client": 2, "seq": 1, "method": "GET", "target": "/h", "unmatched": false,
                "raw": "GET /h HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n",
                "recorded": "GET /h HTTP/1.1\r\nHost: local-tailscaled.sock" })
    );
}

#[test]
fn every_command_once() {
    let dir = TestDir::new();
    let path = dir.socket();
    let mut bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    assert_eq!(bin.line()["event"], json!("listening"));
    assert_eq!(bin.ok(json!({ "cmd": "set-script", "script": rules() })), Value::Null);
    let _watch = every_push(&mut bin, &path);
    every_hold(&mut bin, &path);
    a_resume(&mut bin, &path);
    the_reports(&mut bin);
    assert!(bin.finish().success());
}

#[test]
fn bad_commands_are_answered_and_the_binary_carries_on() {
    let dir = TestDir::new();
    let path = dir.socket();
    let mut bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    bin.line();
    let answer = bin.send_raw("not json");
    assert_eq!((answer["id"].clone(), answer["ok"].clone()), (Value::Null, json!(false)), "{answer}");
    let answer = bin.send(json!({ "cmd": "fly" }));
    assert_eq!(answer["ok"], json!(false));
    assert!(answer["error"].as_str().unwrap().contains("fly"), "{answer}");
    let answer = bin.send(json!({ "cmd": "push-line" }));
    assert_eq!(answer["ok"], json!(false), "a missing argument was accepted: {answer}");
    let answer = bin
        .send(json!({ "cmd": "set-script", "script": { "rules": [{ "match": { "method": "GET" }, "hold": true }] } }));
    assert_eq!(answer["ok"], json!(false), "an invalid script was accepted: {answer}");
    assert_eq!(bin.ok(json!({ "cmd": "connected" })), json!(0));
    assert!(bin.finish().success());
}

#[test]
fn the_end_of_stdin_stops_it_and_removes_the_socket() {
    let dir = TestDir::new();
    let path = dir.socket();
    let bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    bin.line();
    let mut client = Client::connect(&path);
    let status = bin.finish();
    assert!(status.success(), "{status}");
    assert!(!path.exists(), "the socket outlived the binary");
    assert_eq!(client.read_until_closed(), b"");
}

/// The same traffic against `path`: a watch, a GET, a PATCH split over two
/// writes, and an unmatched request.
fn traffic(path: &std::path::Path) {
    let mut watch = Client::connect(path);
    watch.write(&get("/localapi/v0/watch-ipn-bus?mask=18"));
    watch.read_until(|g| g.ends_with(b"\r\n\r\n"));
    let mut r = Client::connect(path);
    r.write(&get("/r?x=1"));
    r.read_until_closed();
    let mut patch = Client::connect(path);
    patch.write(b"PATCH /r HTTP/1.1\r\nContent-Length: 4\r\n\r\n{");
    patch.write(b"\xff}}");
    patch.read_until_closed();
    let mut unmatched = Client::connect(path);
    unmatched.write(&get("/nowhere"));
    unmatched.read_until_closed();
}

#[test]
fn binary_and_library_record_the_same_bytes() {
    let mut script = rules();
    script["rules"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "match": { "method": "PATCH", "path": "/r" }, "reply": { "body": "p" } }));

    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.set_script(serde_json::from_value::<Script>(script.clone()).unwrap()).unwrap();
    traffic(fake.path());
    let in_process: Vec<Value> = fake.requests().iter().map(control::request_json).collect();

    let dir = TestDir::new();
    let path = dir.socket();
    let mut bin = Bin::start(&["--socket", path.to_str().unwrap()]);
    bin.line();
    bin.ok(json!({ "cmd": "set-script", "script": script }));
    traffic(&path);
    let through_binary = bin.ok(json!({ "cmd": "requests" }));

    assert_eq!(in_process.len(), 4);
    assert_eq!(json!(in_process), through_binary);
    assert_eq!(
        through_binary[2]["raw"],
        json!({ "hex": hex(b"PATCH /r HTTP/1.1\r\nContent-Length: 4\r\n\r\n{\xff}}") })
    );
    assert_eq!(through_binary[3]["unmatched"], json!(true));
    assert!(bin.finish().success());
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
