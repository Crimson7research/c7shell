//! The Contract singleton delegates to a backend chosen when it is constructed.
//! The trait knows nothing about Qt: a backend turns requests into snapshots and
//! hands each one to a `Sink`, which the singleton provides (it queues the
//! snapshot onto the Qt thread). Both backends are plain Rust.

use std::io::Write;
use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::Arc;
use std::time::Duration;

use tokio::runtime::Runtime;

use crate::snapshot::{parse, Snapshot};
use crate::spike::read_lines;

/// Name prefix of the real backend's tokio worker thread.
pub const THREAD_NAME: &str = "c7contract-rt";
/// The env var that selects a backend when the singleton is constructed.
pub const ENV_VAR: &str = "C7SPIKE_CONTRACT_BACKEND";

/// Where a backend delivers snapshots. May be called from any thread.
pub type Sink = Arc<dyn Fn(Snapshot) + Send + Sync + 'static>;

pub trait ContractBackend {
    /// What QML reads as `Contract.backend`.
    fn name(&self) -> &'static str;
    /// Starts delivering snapshots to `sink`. Called once, from initialize().
    fn start(&mut self, sink: Sink);
    /// A request from QML. Returns false when it could not be sent.
    fn feed(&self, line: &str) -> bool;
}

/// Picks the backend for an env value: "fake" is the fake, anything else
/// (including unset) is the real tokio backend.
pub fn select(value: Option<&str>) -> Box<dyn ContractBackend> {
    match value {
        Some("fake") => Box::new(FakeBackend::default()),
        _ => Box::new(TokioBackend::new()),
    }
}

/// Reads the env var; what `Default` for the singleton calls.
pub fn from_env() -> Box<dyn ContractBackend> {
    select(std::env::var(ENV_VAR).ok().as_deref())
}

// ---- The real backend: a socket read by a tokio task ----------------------

pub struct TokioBackend {
    runtime: Option<Runtime>,
    writer: Option<StdUnixStream>,
    reader: Option<StdUnixStream>,
}

impl TokioBackend {
    pub fn new() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name(THREAD_NAME)
            .enable_all()
            .build()
            .expect("tokio runtime");
        let (writer, reader) = StdUnixStream::pair().expect("socketpair");
        reader.set_nonblocking(true).expect("nonblocking");
        Self { runtime: Some(runtime), writer: Some(writer), reader: Some(reader) }
    }
}

impl Default for TokioBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl ContractBackend for TokioBackend {
    fn name(&self) -> &'static str {
        "tokio"
    }

    fn start(&mut self, sink: Sink) {
        let Some(reader) = self.reader.take() else { return };
        let Some(rt) = self.runtime.as_ref() else { return };
        rt.spawn(async move {
            let stream = tokio::net::UnixStream::from_std(reader).expect("tokio stream");
            read_lines(stream, |line| sink(parse(&line))).await;
        });
    }

    fn feed(&self, line: &str) -> bool {
        let Some(mut w) = self.writer.as_ref() else { return false };
        writeln!(w, "{line}").is_ok()
    }
}

impl Drop for TokioBackend {
    fn drop(&mut self) {
        self.writer.take(); // EOF ends the reader task
        if let Some(rt) = self.runtime.take() {
            rt.shutdown_timeout(Duration::from_secs(2));
        }
    }
}

// ---- The fake backend: no threads, applies each request as a snapshot ------

#[derive(Default)]
pub struct FakeBackend {
    sink: Option<Sink>,
}

impl ContractBackend for FakeBackend {
    fn name(&self) -> &'static str {
        "fake"
    }

    fn start(&mut self, sink: Sink) {
        self.sink = Some(sink);
    }

    fn feed(&self, line: &str) -> bool {
        let Some(sink) = self.sink.as_ref() else { return false };
        sink(parse(line));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[test]
    fn select_picks_by_value() {
        assert_eq!(select(Some("fake")).name(), "fake");
        assert_eq!(select(None).name(), "tokio");
        assert_eq!(select(Some("other")).name(), "tokio");
    }

    #[test]
    fn fake_delivers_synchronously_after_start() {
        let mut b = FakeBackend::default();
        assert!(!b.feed("state=Running"), "no sink yet");
        let got = Arc::new(Mutex::new(Vec::new()));
        let g = got.clone();
        b.start(Arc::new(move |s| g.lock().unwrap().push(s)));
        assert!(b.feed("state=Running"));
        assert_eq!(got.lock().unwrap()[0].state, Some(5));
    }

    #[test]
    fn tokio_backend_delivers_through_the_socket() {
        let mut b = TokioBackend::new();
        let (tx, rx) = std::sync::mpsc::channel();
        let tx = Mutex::new(tx);
        b.start(Arc::new(move |s| tx.lock().unwrap().send(s).unwrap()));
        assert!(b.feed("active=1"));
        // recv blocks on the channel, not on a clock.
        assert_eq!(rx.recv().unwrap().exit_node_active, Some(true));
        drop(b);
        assert!(rx.recv().is_err(), "sink dropped with the runtime");
    }
}
