//! The fake's socket server: R-FAKE-01, R-FAKE-02, R-FAKE-03 (the fake's
//! half), R-FAKE-05, R-FAKE-06 and R-FAKE-07. Each R-FAKE-06 test ports the
//! `plugin/lib/testing/tests/tst_fakesocketserver.cpp` function of the same
//! name on a38dbca, with the same assertions and barriers in place of waits.

mod support;

use std::fs;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::UnixStream;

use fake_tailscaled::Fake;
use support::TestDir;

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
