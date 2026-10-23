//! Test support shared by the fake's integration tests: a private directory
//! and a raw socket client that stands in for the transport under test.
#![allow(dead_code)]

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

pub mod scenario;

pub use fake_tailscaled::FAILURE_BOUND;

/// A private directory (mode 0700) under the temporary directory, removed
/// when dropped. Its name is short, for the 108-byte `sun_path` limit.
pub struct TestDir {
    path: PathBuf,
}

impl TestDir {
    pub fn new() -> TestDir {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("ft-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).expect("create the test directory");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).expect("make it private");
        TestDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, rest: impl AsRef<Path>) -> PathBuf {
        self.path.join(rest)
    }

    /// The socket path the tests use: nested, so the fake has to create
    /// its parent directories.
    pub fn socket(&self) -> PathBuf {
        self.join("ts/run/tailscaled.sock")
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// A raw client: connect, write, read. Each read is bounded by
/// FAILURE_BOUND, which turns a hang into a failure.
pub struct Client {
    pub stream: UnixStream,
    got: Vec<u8>,
}

impl Client {
    pub fn connect(path: &Path) -> Client {
        let stream = UnixStream::connect(path).unwrap_or_else(|e| panic!("connect to {}: {e}", path.display()));
        stream.set_read_timeout(Some(FAILURE_BOUND)).unwrap();
        stream.set_write_timeout(Some(FAILURE_BOUND)).unwrap();
        Client { stream, got: Vec::new() }
    }

    pub fn write(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).expect("write to the fake");
    }

    /// Everything read so far.
    pub fn got(&self) -> &[u8] {
        &self.got
    }

    /// Reads until `done(everything read so far)` holds, and returns it all.
    /// Panics at end of file or at the failure bound.
    pub fn read_until(&mut self, mut done: impl FnMut(&[u8]) -> bool) -> Vec<u8> {
        let mut buf = [0u8; 4096];
        while !done(&self.got) {
            match self.stream.read(&mut buf) {
                Ok(0) => panic!("end of file before the expected bytes; got {:?}", String::from_utf8_lossy(&self.got)),
                Ok(n) => self.got.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) => panic!("read failed ({e}); got {:?}", String::from_utf8_lossy(&self.got)),
            }
        }
        self.got.clone()
    }

    /// Reads until exactly `n` bytes have been read in all, and returns them.
    pub fn read_exactly(&mut self, n: usize) -> Vec<u8> {
        let got = self.read_until(|g| g.len() >= n);
        assert_eq!(got.len(), n, "read more than {n} bytes: {:?}", String::from_utf8_lossy(&got));
        got
    }

    /// Whether the fake has not closed this connection yet, at this moment:
    /// a read that would block means open, end of file means closed. It
    /// keeps any bytes it reads.
    pub fn is_open(&mut self) -> bool {
        self.stream.set_nonblocking(true).unwrap();
        let mut buf = [0u8; 4096];
        let open = loop {
            match self.stream.read(&mut buf) {
                Ok(0) => break false,
                Ok(n) => self.got.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::WouldBlock => break true,
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(_) => break false,
            }
        };
        self.stream.set_nonblocking(false).unwrap();
        open
    }

    /// Reads until end of file and returns everything read.
    pub fn read_until_closed(&mut self) -> Vec<u8> {
        let mut buf = [0u8; 4096];
        loop {
            match self.stream.read(&mut buf) {
                Ok(0) => return self.got.clone(),
                Ok(n) => self.got.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) if e.kind() == ErrorKind::ConnectionReset => return self.got.clone(),
                Err(e) => panic!("read failed before end of file ({e}); got {:?}", String::from_utf8_lossy(&self.got)),
            }
        }
    }
}
