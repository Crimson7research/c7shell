//! The fake's socket server: R-FAKE-01, R-FAKE-02, R-FAKE-03 (the fake's
//! half), R-FAKE-05, R-FAKE-06 and R-FAKE-07. Each R-FAKE-06 test ports the
//! `plugin/lib/testing/tests/tst_fakesocketserver.cpp` function of the same
//! name on a38dbca, with the same assertions and barriers in place of waits.

mod support;

use std::fs;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use fake_tailscaled::{AfterReply, Fake, Request};
use support::{Client, TestDir};

#[test]
fn r_fake_06_listens_at_the_given_path_for_this_user_only() {
    let dir = TestDir::new();
    let path = dir.socket();
    assert!(!path.parent().unwrap().exists(), "precondition: the parent directory is missing");
    let fake = Fake::start(&path);
    assert!(fake.is_listening(), "{:?}", fake.error());
    assert_eq!(fake.error(), None);
    assert_eq!(fake.path(), path);
    let meta = fs::symlink_metadata(&path).unwrap();
    assert!(meta.file_type().is_socket(), "{} is not a socket", path.display());
    assert_eq!(meta.permissions().mode() & 0o077, 0, "the socket has group or other access");
    let parent = fs::metadata(path.parent().unwrap()).unwrap();
    assert!(parent.is_dir());
    assert_eq!(parent.permissions().mode() & 0o077, 0, "the created directory has group or other access");
}

/// What is at the path before the second fake starts.
enum Taken {
    LiveFake,
    File,
    DanglingSymlink,
}

fn refuses_a_path_already_taken(what: Taken) {
    let dir = TestDir::new();
    let path = dir.socket();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let first = match what {
        Taken::LiveFake => {
            let f = Fake::start(&path);
            assert!(f.is_listening(), "precondition: the first fake listens");
            Some(f)
        }
        Taken::File => {
            fs::write(&path, b"not a socket").unwrap();
            None
        }
        Taken::DanglingSymlink => {
            std::os::unix::fs::symlink(dir.join("nowhere"), &path).unwrap();
            None
        }
    };
    {
        let second = Fake::start(&path);
        assert!(!second.is_listening());
        let error = second.error().expect("a reason");
        assert!(error.contains("already exists"), "{error}");
    }
    // The refused fake, now dropped, removed nothing.
    let meta = fs::symlink_metadata(&path).expect("what was there is still there");
    match what {
        Taken::LiveFake => {
            assert!(meta.file_type().is_socket());
            UnixStream::connect(&path).expect("the first fake still accepts a connection");
            assert!(first.unwrap().is_listening());
        }
        Taken::File => assert_eq!(fs::read(&path).unwrap(), b"not a socket"),
        Taken::DanglingSymlink => {
            assert!(meta.file_type().is_symlink());
            assert_eq!(fs::read_link(&path).unwrap(), dir.join("nowhere"));
        }
    }
}

#[test]
fn r_fake_05_refuses_a_path_already_taken_by_a_live_fake() {
    refuses_a_path_already_taken(Taken::LiveFake);
}

#[test]
fn r_fake_05_refuses_a_path_already_taken_by_a_file() {
    refuses_a_path_already_taken(Taken::File);
}

#[test]
fn r_fake_05_refuses_a_path_already_taken_by_a_dangling_symlink() {
    refuses_a_path_already_taken(Taken::DanglingSymlink);
}

#[test]
fn r_fake_05_a_destroyed_fake_frees_its_path() {
    let dir = TestDir::new();
    let path = dir.socket();
    let first = Fake::start(&path);
    assert!(first.is_listening(), "{:?}", first.error());
    drop(first);
    assert!(fs::symlink_metadata(&path).is_err(), "the destroyed fake left its socket behind");
    let second = Fake::start(&path);
    assert!(second.is_listening(), "{:?}", second.error());
}

#[test]
fn r_fake_06_reports_a_directory_it_cannot_create() {
    let dir = TestDir::new();
    // A file where the directory goes.
    fs::write(dir.join("ts"), b"").unwrap();
    let fake = Fake::start(dir.socket());
    assert!(!fake.is_listening());
    assert!(!fake.error().expect("a reason").is_empty());
}

#[test]
fn r_fake_06_reports_a_path_too_long_to_listen_on() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.join("s".repeat(200)));
    assert!(!fake.is_listening());
    assert!(!fake.error().expect("a reason").is_empty());
}

#[test]
fn a_dropped_fake_that_never_listened_leaves_the_path_alone() {
    let dir = TestDir::new();
    let path = dir.socket();
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, b"x").unwrap();
    drop(Fake::start(&path));
    assert_eq!(fs::read(&path).unwrap(), b"x");
}

/// A handler that answers every request with `reply`.
fn reply_with(reply: &'static [u8]) -> fake_tailscaled::Handler {
    Box::new(move |_: &Request| Some(reply.to_vec()))
}

/// The recorded bytes of every request, in order.
fn recorded(fake: &Fake) -> Vec<Vec<u8>> {
    fake.requests().into_iter().map(|r| r.recorded).collect()
}

/// Waits until the fake has received `n` bytes from client `id` in all.
fn wait_received(fake: &Fake, id: usize, n: usize) {
    fake.wait_until(&format!("{n} bytes received from client {id}"), |s| (s.received(id) == n).then_some(()));
}

#[test]
fn r_fake_01_frames_a_request_with_its_declared_body() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"ok"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    let mut client = Client::connect(fake.path());
    let partial: &[u8] = b"PATCH /p HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":";
    client.write(partial);
    // The fake barrier: every byte of the partial PATCH has been consumed.
    wait_received(&fake, 1, partial.len());
    assert!(fake.requests().is_empty(), "a request with half its body was framed as whole");
    client.write(b"true}");
    assert_eq!(client.read_exactly(2), b"ok");
    assert_eq!(recorded(&fake), vec![b"PATCH /p HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":true}".to_vec()]);
    // The body was consumed, not left to be read as the next request's head.
    client.write(b"GET /q HTTP/1.1\r\n\r\n");
    fake.wait_until("a second request", |s| (s.requests().len() == 2).then_some(()));
    assert_eq!(recorded(&fake)[1], b"GET /q HTTP/1.1");
}

#[test]
fn r_fake_06_replies_and_closes_like_a_request_socket() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(
        Box::new(|r: &Request| Some([b"ok:".as_slice(), &r.recorded].concat())),
        AfterReply::CloseAfterReply,
        None,
    );
    let mut client = Client::connect(fake.path());
    client.write(b"dispatch workspace 2");
    assert_eq!(client.read_until_closed(), b"ok:dispatch workspace 2");
    assert_eq!(recorded(&fake), vec![b"dispatch workspace 2".to_vec()]);
}

#[test]
fn r_fake_06_can_keep_the_client_open() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"pong"), AfterReply::KeepOpen, None);
    let mut client = Client::connect(fake.path());
    for i in 1..=2 {
        client.write(b"ping");
        assert_eq!(client.read_exactly(4 * i), b"pong".repeat(i));
    }
    assert!(client.is_open());
    assert_eq!(fake.requests().len(), 2);
}

#[test]
fn r_fake_06_splits_framed_requests_whatever_the_reads_look_like() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(
        Box::new(|r: &Request| Some([b"<".as_slice(), &r.recorded, b">"].concat())),
        AfterReply::KeepOpen,
        Some(b"\n"),
    );
    // #286's sequence: two requests over two writes, then one without its
    // delimiter, which is not a request yet.
    let mut client = Client::connect(fake.path());
    client.write(b"one\ntw");
    wait_received(&fake, 1, 6);
    client.write(b"o\nthree");
    assert_eq!(client.read_exactly(10), b"<one><two>");
    wait_received(&fake, 1, 13);
    assert_eq!(recorded(&fake), vec![b"one".to_vec(), b"two".to_vec()]);
    client.write(b"\n");
    assert_eq!(client.read_exactly(17), b"<one><two><three>");

    // Every split of two requests into two reads, the fake barrier between
    // them so that each write is its own read.
    let message: &[u8] = b"one\ntwo\n";
    for at in 1..message.len() {
        let mut client = Client::connect(fake.path());
        let id = at + 1;
        client.write(&message[..at]);
        wait_received(&fake, id, at);
        client.write(&message[at..]);
        assert_eq!(client.read_exactly(10), b"<one><two>", "split at {at}");
    }
    // And both in one write.
    let mut client = Client::connect(fake.path());
    client.write(message);
    assert_eq!(client.read_exactly(10), b"<one><two>");
}

#[test]
fn r_fake_06_answers_nothing_after_closing() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(Box::new(|r: &Request| Some(r.recorded.clone())), AfterReply::CloseAfterReply, Some(b"\n"));
    let mut client = Client::connect(fake.path());
    client.write(b"a\nb\n");
    assert_eq!(client.read_until_closed(), b"a");
    assert_eq!(recorded(&fake), vec![b"a".to_vec()]);
}

#[test]
fn r_fake_06_records_requests_without_a_handler() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let mut client = Client::connect(fake.path());
    client.write(b"j/clients");
    fake.wait_until("a request", |s| (!s.requests().is_empty()).then_some(()));
    assert_eq!(recorded(&fake)[0], b"j/clients");
    assert!(client.is_open());
    assert!(client.got().is_empty(), "nothing is written without a handler");
}

#[test]
fn a_handler_that_returns_none_writes_nothing_and_keeps_the_client() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(Box::new(|_: &Request| None), AfterReply::CloseAfterReply, Some(b"\n"));
    let mut client = Client::connect(fake.path());
    client.write(b"x\n");
    fake.wait_until("a request", |s| (s.requests().len() == 1).then_some(()));
    assert!(client.is_open());
    assert!(client.got().is_empty());
}

#[test]
fn requests_carry_their_client_and_sequence() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"k"), AfterReply::KeepOpen, Some(b"\n"));
    let mut a = Client::connect(fake.path());
    a.write(b"1\n");
    a.read_exactly(1);
    let mut b = Client::connect(fake.path());
    b.write(b"2\n");
    b.read_exactly(1);
    let got: Vec<(usize, usize)> = fake.requests().iter().map(|r| (r.client, r.seq)).collect();
    assert_eq!(got, vec![(1, 0), (2, 1)]);
}

#[test]
#[should_panic(expected = "the fake never reached: something that never happens")]
fn a_wait_that_is_never_reached_fails_naming_it() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.wait_until_within("something that never happens", std::time::Duration::ZERO, |_| None::<()>);
}

/// Waits until the fake counts exactly `n` connected clients.
fn wait_connected(fake: &Fake, n: usize) {
    fake.wait_until(&format!("{n} connected clients"), |s| (s.connected_count() == n).then_some(()));
}

/// Waits until the fake has recorded `n` requests.
fn wait_requests(fake: &Fake, n: usize) {
    fake.wait_until(&format!("{n} requests recorded"), |s| (s.requests().len() == n).then_some(()));
}

const STATUS_GET: &[u8] = b"GET /status HTTP/1.1\r\n\r\n";

#[test]
fn r_fake_02_pushes_exact_bytes_and_holds_a_request() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"handled"), AfterReply::CloseAfterReply, Some(b"\r\n\r\n"));

    // Exact bytes, half a line at a time.
    let mut client = Client::connect(fake.path());
    wait_connected(&fake, 1);
    assert_eq!(fake.push_chunk(b"{\"half\":"), 1);
    assert_eq!(client.read_exactly(8), b"{\"half\":");
    assert_eq!(fake.push_chunk(b"1}\n"), 1);
    assert_eq!(client.read_exactly(11), b"{\"half\":1}\n");
    drop(client);
    wait_connected(&fake, 0);

    // A hold: recorded, unanswered, connected, and skipped by a push.
    fake.hold_next(b"/status ");
    let mut first = Client::connect(fake.path());
    first.write(STATUS_GET);
    wait_requests(&fake, 1);
    assert_eq!(fake.held_count(), 1);
    assert_eq!(fake.push_line(b"pushed"), 0);
    assert_eq!(fake.wait_until("the held client's written report", |s| Some(s.written(2))), 0);
    assert_eq!(fake.complete_held(b"completed"), 1);
    assert_eq!(first.read_until_closed(), b"completed");

    // The hold was one-shot: the next GET is answered by the handler.
    let mut second = Client::connect(fake.path());
    second.write(STATUS_GET);
    assert_eq!(second.read_until_closed(), b"handled");
    assert_eq!(fake.held_count(), 0);

    // Holds accumulate.
    fake.hold_next(b"/status ");
    let mut third = Client::connect(fake.path());
    third.write(STATUS_GET);
    wait_requests(&fake, 3);
    assert_eq!(fake.held_count(), 1);
    fake.hold_next(b"/status ");
    let mut fourth = Client::connect(fake.path());
    fourth.write(STATUS_GET);
    wait_requests(&fake, 4);
    assert_eq!(fake.held_count(), 2);
    assert_eq!(fake.complete_held(b"both"), 2);
    assert_eq!(third.read_until_closed(), b"both");
    assert_eq!(fourth.read_until_closed(), b"both");

    // A completion reaches only what is held when it runs: the hold armed
    // before it still holds the request sent after it.
    fake.hold_next(b"/status ");
    let mut held = Client::connect(fake.path());
    held.write(STATUS_GET);
    wait_requests(&fake, 5);
    assert_eq!(fake.held_count(), 1);
    fake.hold_next(b"/status ");
    assert_eq!(fake.complete_held(b"once"), 1);
    assert_eq!(held.read_until_closed(), b"once");
    let mut fifth = Client::connect(fake.path());
    fifth.write(STATUS_GET);
    wait_requests(&fake, 6);
    assert_eq!(fake.held_count(), 1);
    let id = fake.requests()[5].client;
    assert_eq!(fake.wait_until("the fifth client's written report", |s| Some(s.written(id))), 0);
    assert!(fifth.is_open());
    assert!(fifth.got().is_empty(), "the fifth client received {:?}", fifth.got());
}

#[test]
fn a_hold_matches_only_its_fragment() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"handled"), AfterReply::CloseAfterReply, Some(b"\r\n\r\n"));
    fake.hold_next(b"/status ");
    let mut other = Client::connect(fake.path());
    other.write(b"GET /status?x HTTP/1.1\r\n\r\n");
    assert_eq!(other.read_until_closed(), b"handled");
    assert_eq!(fake.held_count(), 0);
    // Still armed for the request that matches.
    let mut held = Client::connect(fake.path());
    held.write(STATUS_GET);
    wait_requests(&fake, 2);
    assert_eq!(fake.held_count(), 1);
    // A held client that goes away is no longer held.
    drop(held);
    fake.wait_until("the held client gone", |s| (s.held_count() == 0).then_some(()));
    assert_eq!(fake.complete_held(b"late"), 0);
}

#[test]
fn an_armed_hold_is_reported_until_a_request_uses_it() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"answered"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    assert_eq!(fake.armed_hold(), None);
    fake.hold_next(b"/status ");
    assert_eq!(fake.armed_hold(), Some(b"/status ".to_vec()));
    let mut client = Client::connect(fake.path());
    client.write(STATUS_GET);
    wait_requests(&fake, 1);
    assert_eq!(fake.armed_hold(), None, "the hold was used");
}

#[test]
fn completing_with_keep_open_leaves_the_client_connected() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"k"), AfterReply::KeepOpen, Some(b"\n"));
    fake.hold_next(b"x");
    let mut client = Client::connect(fake.path());
    client.write(b"x\n");
    wait_requests(&fake, 1);
    assert_eq!(fake.complete_held(b"done"), 1);
    assert_eq!(client.read_exactly(4), b"done");
    client.write(b"y\n");
    assert_eq!(client.read_exactly(5), b"donek");
}

#[test]
fn r_fake_06_pushes_lines_to_every_client_like_an_event_socket() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let mut first = Client::connect(fake.path());
    let mut second = Client::connect(fake.path());
    wait_connected(&fake, 2);
    assert_eq!(fake.push_line(b"workspace>>2"), 2);
    assert_eq!(first.read_until(|g| g.ends_with(b"\n")), b"workspace>>2\n");
    assert_eq!(second.read_until(|g| g.ends_with(b"\n")), b"workspace>>2\n");
}

#[test]
fn r_fake_06_says_when_a_line_reached_nobody() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    assert_eq!(fake.push_line(b"workspace>>2"), 0);
}

#[test]
fn a_write_the_client_never_takes_is_recorded_as_a_fault() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let _client = Client::connect(fake.path());
    wait_connected(&fake, 1);
    assert_eq!(fake.faults(), Vec::<String>::new());
    // The new bound reaches the client already connected: the write gives
    // up long before the default bound would let it.
    fake.set_write_timeout(Duration::from_millis(1));
    let (done, pushed) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // Far more than a Unix socket buffer holds, to a client that never reads.
        let took = fake.push_chunk(&vec![b'x'; 16 << 20]);
        let _ = done.send((took, fake));
    });
    let (took, fake) =
        pushed.recv_timeout(fake_tailscaled::FAILURE_BOUND / 2).expect("the write kept the default bound");
    assert_eq!(took, 0);
    let faults = fake.faults();
    assert_eq!(faults.len(), 1, "{faults:?}");
    assert!(faults[0].starts_with("a write to client 1 timed out"), "{faults:?}");
}

#[test]
fn push_to_reaches_one_chosen_client() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let mut first = Client::connect(fake.path());
    let mut second = Client::connect(fake.path());
    wait_connected(&fake, 2);
    assert!(fake.push_to(2, b"two"));
    assert_eq!(second.read_exactly(3), b"two");
    assert!(!fake.push_to(99, b"nobody"));
    drop(second);
    wait_connected(&fake, 1);
    assert!(!fake.push_to(2, b"gone"));
    assert_eq!(fake.push_line(b"one"), 1);
    assert_eq!(first.read_exactly(4), b"one\n");
}

#[test]
fn r_fake_07_reports_what_the_barriers_read() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"ok"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    assert_eq!(fake.clients(), vec![]);
    assert_eq!((fake.connected_count(), fake.accepted_total(), fake.disconnects()), (0, 0, 0));

    let get: &[u8] = b"GET /q HTTP/1.1\r\n\r\n";
    assert_eq!(get.len(), 19);
    let mut one = Client::connect(fake.path());
    one.write(get);
    assert_eq!(one.read_exactly(2), b"ok");
    let c1 = &fake.clients()[0];
    assert_eq!((c1.id, c1.connected, c1.received, c1.written, c1.held), (1, true, 19, 2, false));
    assert_eq!((fake.connected_count(), fake.accepted_total()), (1, 1));

    assert_eq!(fake.push_line(b"abc"), 1);
    assert_eq!(one.read_exactly(6), b"okabc\n");
    assert_eq!(fake.clients()[0].written, 6);

    one.write(b"GET /");
    fake.wait_until("24 bytes received from client 1", |s| (s.clients()[0].received == 24).then_some(()));
    assert_eq!(fake.requests().len(), 1, "a request without its delimiter was recorded");

    let mut two = Client::connect(fake.path());
    two.write(get);
    assert_eq!(two.read_exactly(2), b"ok");
    assert_eq!((fake.connected_count(), fake.accepted_total()), (2, 2));
    let c2 = &fake.clients()[1];
    assert_eq!((c2.id, c2.received, c2.written), (2, 19, 2));

    let before = fake.disconnects();
    drop(one);
    fake.wait_until("client 1's disconnect handled", |s| (s.disconnects() == before + 1).then_some(()));
    assert_eq!(fake.connected_count(), 1);
    assert_eq!(fake.accepted_total(), 2);
    assert!(!fake.clients()[0].connected);
    assert!(fake.clients()[1].connected);
}

#[test]
fn r_fake_03_drops_one_chosen_client() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"answered"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    // A client already answered and kept open, standing in for the watch.
    let mut watch = Client::connect(fake.path());
    watch.write(b"GET /watch HTTP/1.1\r\n\r\n");
    assert_eq!(watch.read_exactly(8), b"answered");
    // A held GET of /status.
    fake.hold_next(b"/status ");
    let mut held = Client::connect(fake.path());
    held.write(STATUS_GET);
    wait_requests(&fake, 2);
    assert_eq!(fake.held_count(), 1);
    assert_eq!(fake.connected_count(), 2);
    let clients = fake.clients();
    assert_eq!((clients[0].held, clients[1].held), (false, true), "{clients:?}");

    let id = fake.client_holding(b"/status ").expect("the held client");
    assert_eq!(id, 2);
    let before = fake.disconnects();
    assert!(fake.close_client(id));
    assert_eq!(held.read_until_closed(), b"", "the held client got bytes before its end of file");
    fake.wait_until("the closed client's disconnect", |s| (s.disconnects() == before + 1).then_some(()));
    assert_eq!(fake.connected_count(), 1, "closing one client dropped another");
    assert_eq!(fake.held_count(), 0);
    assert_eq!(fake.client_holding(b"/status "), None);

    // The other client is still served, and so is a new one.
    assert_eq!(fake.push_line(b"event"), 1);
    assert_eq!(watch.read_exactly(14), b"answeredevent\n");
    let mut later = Client::connect(fake.path());
    later.write(STATUS_GET);
    assert_eq!(later.read_exactly(8), b"answered");
    assert!(fake.is_listening());
}

#[test]
fn r_fake_03_finds_the_held_client_by_its_fragment() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"answered"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    fake.hold_next(b"/status ");
    let mut status = Client::connect(fake.path());
    status.write(STATUS_GET);
    wait_requests(&fake, 1);
    fake.hold_next(b"/prefs ");
    let mut prefs = Client::connect(fake.path());
    prefs.write(b"GET /prefs HTTP/1.1\r\n\r\n");
    wait_requests(&fake, 2);
    assert_eq!(fake.held_count(), 2);

    assert_eq!(fake.client_holding(b"/status "), Some(1));
    assert_eq!(fake.client_holding(b"/prefs "), Some(2));
    assert_eq!(fake.client_holding(b"/suggest "), None, "no held request carries that fragment");
}

#[test]
fn closing_a_client_that_is_gone_or_unknown_says_so() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    let client = Client::connect(fake.path());
    wait_connected(&fake, 1);
    assert!(!fake.close_client(7));
    drop(client);
    wait_connected(&fake, 0);
    assert!(!fake.close_client(1));
}

#[test]
fn r_fake_06_disconnects_its_clients_and_removes_the_socket_when_destroyed() {
    let dir = TestDir::new();
    let path = dir.socket();
    let fake = Fake::start(&path);
    let mut first = Client::connect(&path);
    let mut second = Client::connect(&path);
    wait_connected(&fake, 2);
    drop(fake);
    assert_eq!(first.read_until_closed(), b"");
    assert_eq!(second.read_until_closed(), b"");
    assert!(fs::symlink_metadata(&path).is_err(), "the socket file is still there");
}

#[test]
fn a_fake_whose_socket_was_replaced_leaves_the_new_file_alone() {
    let dir = TestDir::new();
    let path = dir.socket();
    let fake = Fake::start(&path);
    fs::remove_file(&path).unwrap();
    fs::write(&path, b"someone else's").unwrap();
    drop(fake);
    assert_eq!(fs::read(&path).unwrap(), b"someone else's");
}

#[test]
fn dropping_a_fake_whose_path_another_fake_took_neither_hangs_nor_reaches_it() {
    let dir = TestDir::new();
    let path = dir.socket();
    let first = Fake::start(&path);
    fs::remove_file(&path).unwrap();
    let second = Fake::start(&path);
    assert!(second.is_listening(), "precondition: {:?}", second.error());
    let (done, dropped) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        drop(first);
        let _ = done.send(());
    });
    dropped.recv_timeout(fake_tailscaled::FAILURE_BOUND).expect("dropping the first fake hung");
    assert_eq!(second.accepted_total(), 0, "the first fake's drop connected to the second");
    assert!(fs::symlink_metadata(&path).unwrap().file_type().is_socket(), "the second fake's socket was removed");
    let _client = Client::connect(&path);
    wait_connected(&second, 1);
}

#[test]
fn r_fake_01_reads_content_length_in_any_case() {
    let dir = TestDir::new();
    let fake = Fake::start(dir.socket());
    fake.on_request(reply_with(b"ok"), AfterReply::KeepOpen, Some(b"\r\n\r\n"));
    let mut client = Client::connect(fake.path());
    client.write(b"PATCH /p HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}GET /q HTTP/1.1\r\n\r\n");
    wait_requests(&fake, 2);
    let requests = fake.requests();
    assert_eq!(requests[0].recorded, b"PATCH /p HTTP/1.1\r\ncontent-length: 2\r\n\r\n{}");
    assert_eq!(requests[1].recorded, b"GET /q HTTP/1.1");
}
