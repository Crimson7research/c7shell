//! Byte-exact output of every reply form a scenario can script, read by a
//! raw client standing in for the transport.

mod support;

use fake_tailscaled::{Body, Bytes, Fake, Script};
use serde_json::json;
use support::{Client, TestDir};

/// A fake running `rules` (the scenario format's `fake.rules`).
fn scripted(dir: &TestDir, rules: serde_json::Value) -> Fake {
    let fake = Fake::start(dir.socket());
    assert!(fake.is_listening(), "{:?}", fake.error());
    let script: Script = serde_json::from_value(json!({ "rules": rules })).expect("a valid script");
    fake.set_script(script).expect("an encodable script");
    fake
}

fn get(path: &str) -> Vec<u8> {
    format!("GET {path} HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n").into_bytes()
}

/// One GET of `/r` against a fake answering it with `reply`; returns every
/// byte up to the fake's close.
fn reply_bytes(reply: serde_json::Value) -> Vec<u8> {
    let dir = TestDir::new();
    let fake = scripted(&dir, json!([{ "match": { "method": "GET", "target": "/r" }, "reply": reply }]));
    let mut client = Client::connect(fake.path());
    client.write(&get("/r"));
    client.read_until_closed()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn content_length_is_added_and_the_body_is_exact() {
    let got = reply_bytes(json!({ "status": 200, "framing": "content-length", "body": "hello" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
}

#[test]
fn content_length_is_the_default_framing() {
    let got = reply_bytes(json!({ "status": 200, "body": "hi" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi");
}

#[test]
fn a_declared_wrong_length_is_sent_as_declared() {
    let got = reply_bytes(json!({ "status": 200, "framing": { "content-length": 99 }, "body": "123456789" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n123456789");
}

#[test]
fn chunked_sends_one_chunk_and_the_final_chunk() {
    let got = reply_bytes(json!({ "status": 200, "framing": "chunked", "body": "hello world" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nb\r\nhello world\r\n0\r\n\r\n");
}

#[test]
fn chunked_with_given_sizes() {
    let got =
        reply_bytes(json!({ "status": 200, "framing": { "chunked": { "sizes": [6, 7] } }, "body": "hello, world!" }));
    assert_eq!(
        text(&got),
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nhello,\r\n7\r\n world!\r\n0\r\n\r\n"
    );
}

#[test]
fn chunked_with_an_extension_and_a_trailer() {
    let got = reply_bytes(json!({ "status": 200,
        "framing": { "chunked": { "extension": ";ext=1", "trailers": [["X-Trailer", "1"]] } }, "body": "hello" }));
    assert_eq!(
        text(&got),
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n0;ext=1\r\nX-Trailer: 1\r\n\r\n"
    );
}

#[test]
fn chunked_without_the_final_chunk() {
    let got = reply_bytes(json!({ "status": 200, "framing": { "chunked": { "final": false } }, "body": "hello" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n");
}

#[test]
fn chunk_sizes_must_add_up_to_the_body() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let script: Script = serde_json::from_value(json!({ "rules": [{ "match": { "method": "GET", "target": "/r" },
        "reply": { "framing": { "chunked": { "sizes": [1] } }, "body": "hello" } }] }))
    .unwrap();
    let error = fake.set_script(script).unwrap_err();
    assert!(error.contains("sizes"), "{error}");
}

#[test]
fn no_framing_then_close() {
    let got = reply_bytes(json!({ "status": 200, "framing": "none", "body": "hello" }));
    assert_eq!(text(&got), "HTTP/1.1 200 OK\r\n\r\nhello");
}

#[test]
fn no_framing_then_keep_open() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([{ "match": { "method": "GET", "target": "/r" },
        "reply": { "framing": "none", "body": "hello", "then": "keep-open" } }]),
    );
    let mut client = Client::connect(fake.path());
    client.write(&get("/r"));
    let want = b"HTTP/1.1 200 OK\r\n\r\nhello";
    assert_eq!(client.read_exactly(want.len()), want);
    assert!(client.is_open());
    assert_eq!(fake.connected_count(), 1);
}

#[test]
fn a_403_with_a_body() {
    let got = reply_bytes(json!({ "status": 403, "body": "prefs write access denied\n" }));
    assert_eq!(text(&got), "HTTP/1.1 403 Forbidden\r\nContent-Length: 26\r\n\r\nprefs write access denied\n");
}

#[test]
fn a_500_with_a_json_body_serialised_compactly() {
    let got = reply_bytes(json!({ "status": 500, "body": { "json": { "error": "boom" } } }));
    assert_eq!(text(&got), "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 16\r\n\r\n{\"error\":\"boom\"}");
}

#[test]
fn a_reason_and_headers_are_sent_verbatim_and_in_order() {
    let got = reply_bytes(json!({ "status": 403, "reason": "Nope",
        "headers": [["Content-Type", "text/plain; charset=utf-8"], ["x-b", "2"]], "body": "no" }));
    assert_eq!(
        text(&got),
        "HTTP/1.1 403 Nope\r\nContent-Type: text/plain; charset=utf-8\r\nx-b: 2\r\nContent-Length: 2\r\n\r\nno"
    );
}

#[test]
fn raw_status_lines() {
    let got = reply_bytes(json!({ "status_line": "garbage" }));
    assert_eq!(text(&got), "garbage\r\nContent-Length: 0\r\n\r\n");
    let got = reply_bytes(json!({ "status_line": "HTTP/1.1 abc OK" }));
    assert_eq!(text(&got), "HTTP/1.1 abc OK\r\nContent-Length: 0\r\n\r\n");
}

#[test]
fn a_body_in_hex() {
    let got = reply_bytes(json!({ "status": 500, "body": { "hex": "62616420ff20656e64" } }));
    assert_eq!(got, b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 9\r\n\r\nbad \xff end");
}

#[test]
fn close_without_reply() {
    let got = reply_bytes(json!({ "then": "close-without-reply" }));
    assert_eq!(got, b"");
}

#[test]
fn a_split_waits_for_its_release() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([{ "match": { "method": "GET", "target": "/r" },
        "reply": { "status": 200, "body": "0123456789".repeat(5), "split": [{ "at": 40, "await": "rest" }] } }]),
    );
    let mut client = Client::connect(fake.path());
    client.write(&get("/r"));
    let whole = format!("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{}", "0123456789".repeat(5)).into_bytes();
    assert_eq!(client.read_exactly(40), &whole[..40]);
    fake.wait_until("client 1 parked", |s| s.clients()[0].parked.then_some(()));
    assert_eq!(fake.clients()[0].written, 40);
    assert_eq!(fake.push_line(b"stray"), 0, "a push reached a parked client");
    assert_eq!(fake.resume("other"), 0);
    assert_eq!(fake.resume("rest"), 1);
    assert_eq!(client.read_until_closed(), whole);
    assert!(!fake.clients()[0].parked);
}

#[test]
fn several_splits_release_in_order() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([{ "match": { "method": "GET", "target": "/r" },
        "reply": { "status_line": "X", "framing": "none", "body": "abcdef",
                   "split": [{ "at": 3, "await": "one" }, { "at": 7, "await": "two" }] } }]),
    );
    let mut client = Client::connect(fake.path());
    client.write(&get("/r"));
    assert_eq!(client.read_exactly(3), b"X\r\n");
    assert_eq!(fake.resume("two"), 0, "released out of order");
    assert_eq!(fake.resume("one"), 1);
    assert_eq!(client.read_exactly(7), b"X\r\n\r\nab");
    assert_eq!(fake.resume("two"), 1);
    assert_eq!(client.read_until_closed(), b"X\r\n\r\nabcdef");
}

#[test]
fn split_offsets_must_increase_and_stay_inside_the_reply() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    for split in [json!([{ "at": 5, "await": "a" }, { "at": 5, "await": "b" }]), json!([{ "at": 999, "await": "a" }])] {
        let script: Script = serde_json::from_value(json!({ "rules": [{ "match": { "method": "GET", "target": "/r" },
            "reply": { "body": "x", "split": split } }] }))
        .unwrap();
        let error = fake.set_script(script).unwrap_err();
        assert!(error.contains("split"), "{error}");
    }
}

#[test]
fn a_stream_rule_keeps_the_client_for_watch_lines() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([
            { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" },
              "stream": { "status": 200, "framing": "chunked" } },
            { "match": { "method": "GET", "path": "/other" }, "reply": { "then": "keep-open" } }
        ]),
    );
    let mut watch = Client::connect(fake.path());
    watch.write(&get("/localapi/v0/watch-ipn-bus?mask=18"));
    let head = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n";
    assert_eq!(watch.read_exactly(head.len()), head);
    let mut other = Client::connect(fake.path());
    other.write(&get("/other"));
    other.read_exactly(38);
    fake.wait_until("the watch is a stream", |s| s.clients()[0].stream.then_some(()));
    assert!(!fake.clients()[1].stream);
    assert_eq!(fake.push_watch_line(b"{\"a\":1}"), 1);
    let line = b"8\r\n{\"a\":1}\n\r\n";
    assert_eq!(watch.read_exactly(head.len() + line.len()), [head.as_slice(), line].concat());
    assert!(watch.is_open());
    assert_eq!(other.got().len(), 38, "a watch line reached a client that is not a stream");
}

#[test]
fn times_falls_through_to_the_next_rule() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([
            { "match": { "method": "GET", "target": "/r" }, "times": 1, "reply": { "body": "first" } },
            { "match": { "method": "GET", "target": "/r" }, "times": "always", "reply": { "body": "rest" } }
        ]),
    );
    for want in ["first", "rest", "rest"] {
        let mut client = Client::connect(fake.path());
        client.write(&get("/r"));
        let got = client.read_until_closed();
        assert!(text(&got).ends_with(&format!("\r\n\r\n{want}")), "{}", text(&got));
    }
}

#[test]
fn a_path_rule_ignores_the_query_and_the_method_must_match() {
    let dir = TestDir::new();
    let fake = scripted(&dir, json!([{ "match": { "method": "GET", "path": "/p" }, "reply": { "body": "p" } }]));
    let mut client = Client::connect(fake.path());
    client.write(&get("/p?x=1"));
    assert!(text(&client.read_until_closed()).ends_with("\r\n\r\np"));
    let mut client = Client::connect(fake.path());
    client.write(b"PATCH /p HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}");
    assert!(text(&client.read_until_closed()).starts_with("HTTP/1.1 404 Not Found"));
}

#[test]
fn an_unmatched_request_gets_404_and_is_flagged() {
    let dir = TestDir::new();
    let fake = scripted(&dir, json!([{ "match": { "method": "GET", "target": "/r" }, "reply": { "body": "r" } }]));
    let mut client = Client::connect(fake.path());
    client.write(&get("/nowhere"));
    assert_eq!(text(&client.read_until_closed()), "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
    let requests = fake.requests();
    assert_eq!(requests.len(), 1);
    assert!(requests[0].unmatched);
    assert_eq!(requests[0].target(), "/nowhere");
}

#[test]
fn a_hold_rule_is_released_by_complete_held() {
    let dir = TestDir::new();
    let fake = scripted(&dir, json!([{ "match": { "method": "GET", "target": "/r" }, "hold": true }]));
    let mut client = Client::connect(fake.path());
    client.write(&get("/r"));
    fake.wait_until("the request held", |s| (s.held_count() == 1).then_some(()));
    assert!(!fake.requests()[0].unmatched);
    assert_eq!(fake.complete_held(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"), 1);
    assert_eq!(text(&client.read_until_closed()), "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
}

#[test]
fn a_patch_body_is_framed_by_its_length() {
    let dir = TestDir::new();
    let fake = scripted(
        &dir,
        json!([{ "match": { "method": "PATCH", "target": "/localapi/v0/prefs" }, "reply": { "body": "{}" } }]),
    );
    let mut client = Client::connect(fake.path());
    let patch: &[u8] = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nHost: local-tailscaled.sock\r\nContent-Type: application/json\r\nContent-Length: 14\r\n\r\n{\"RouteAll\":1}";
    client.write(&patch[..patch.len() - 1]);
    fake.wait_until("all but the last body byte", |s| (s.received(1) == patch.len() - 1).then_some(()));
    assert!(fake.requests().is_empty());
    client.write(&patch[patch.len() - 1..]);
    assert_eq!(text(&client.read_until_closed()), "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
    let requests = fake.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].raw, patch);
    assert_eq!(requests[0].body(), b"{\"RouteAll\":1}");
}

#[test]
fn bytes_round_trip_through_json() {
    let utf8: Bytes = serde_json::from_value(json!("héllo\r\n")).unwrap();
    assert_eq!(utf8.0, "héllo\r\n".as_bytes());
    assert_eq!(serde_json::to_value(&utf8).unwrap(), json!("héllo\r\n"));

    let hex: Bytes = serde_json::from_value(json!({ "hex": "00ff41" })).unwrap();
    assert_eq!(hex.0, vec![0x00, 0xff, 0x41]);
    assert_eq!(serde_json::to_value(&hex).unwrap(), json!({ "hex": "00ff41" }));

    let body: Body = serde_json::from_value(json!({ "json": { "a": [1, true, null] } })).unwrap();
    assert_eq!(body.0, b"{\"a\":[1,true,null]}");
    let body: Body = serde_json::from_value(json!({ "hex": "4142" })).unwrap();
    assert_eq!(body.0, b"AB");

    for bad in
        [json!({ "hex": "0" }), json!({ "hex": "zz" }), json!(3), json!({ "json": 1 }), json!({ "hex": "00", "x": 1 })]
    {
        assert!(serde_json::from_value::<Bytes>(bad.clone()).is_err(), "{bad} was accepted as Bytes");
    }
    assert!(serde_json::from_value::<Body>(json!({ "nope": 1 })).is_err());
}

/// A reply the fake writes under its lock must fit an unread Unix socket
/// buffer, or a client on the thread waiting for that lock never drains it.
#[test]
fn a_reply_over_the_write_limit_is_refused() {
    let rule = |body: String| json!({ "rules": [{ "match": { "method": "GET", "target": "/r" }, "reply": { "body": body } }] });
    let script: Script = serde_json::from_value(rule("x".repeat(fake_tailscaled::MAX_WRITE + 1))).unwrap();
    let e = script.validate().unwrap_err();
    assert!(e.starts_with("rules[0]: ") && e.contains("over the fake's 131072-byte write limit"), "{e}");
    // R-HTTP-09's 65 536-byte bodies fit.
    let fits: Script = serde_json::from_value(rule("x".repeat(65_536))).unwrap();
    fits.validate().unwrap();
    // So must a stream head.
    let head = json!({ "rules": [{ "match": { "method": "GET", "target": "/w" },
        "stream": { "headers": [["X-Pad", "x".repeat(fake_tailscaled::MAX_WRITE)]] } }] });
    let e = serde_json::from_value::<Script>(head).unwrap().validate().unwrap_err();
    assert!(e.contains("write limit"), "{e}");
}

#[test]
fn a_zero_chunk_size_is_refused() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let script: Script = serde_json::from_value(json!({ "rules": [{ "match": { "method": "GET", "target": "/r" },
        "reply": { "framing": { "chunked": { "sizes": [0, 5] } }, "body": "hello" } }] }))
    .unwrap();
    let error = fake.set_script(script).unwrap_err();
    assert!(error.contains("framing.chunked.sizes"), "{error}");
}

