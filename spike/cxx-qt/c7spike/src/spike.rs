//! Spike: the QML singleton. It owns a tokio runtime whose task reads lines
//! from a Unix socket and hands results to the Qt thread with CxxQtThread::queue.

use core::pin::Pin;
use std::io::Write;
use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cxx_qt::{CxxQtThread, CxxQtType, Threading};
use cxx_qt_lib::QString;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::runtime::Runtime;

use crate::bridge::qobject::{PeerModel, Spike};
use crate::peers::parse;

/// Name prefix of every tokio thread, so tests can find them in /proc/self/task.
pub const THREAD_NAME: &str = "c7spike-tokio";

// Process-wide counters. The plugin library stays loaded across engines, so a
// later engine can read what happened to an earlier one.
static LIVE_RUNTIMES: AtomicI32 = AtomicI32::new(0);
static CREATED_RUNTIMES: AtomicI32 = AtomicI32::new(0);
static ATTEMPTED: AtomicI32 = AtomicI32::new(0);
static REFUSED: AtomicI32 = AtomicI32::new(0);
static RAN: AtomicI32 = AtomicI32::new(0);
static DROPPED_UNRUN: AtomicI32 = AtomicI32::new(0);
static LATE: AtomicI32 = AtomicI32::new(0);

pub struct SpikeRust {
    pub(crate) counter: i32,
    pub(crate) state: QString,
    runtime: Option<Runtime>,
    writer: Option<StdUnixStream>,
    reader: Option<StdUnixStream>,
    model: Arc<Mutex<Option<CxxQtThread<PeerModel>>>>,
    alive: Arc<AtomicBool>,
}

impl Default for SpikeRust {
    fn default() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name(THREAD_NAME)
            .enable_all()
            .build()
            .expect("tokio runtime");
        let (writer, reader) = StdUnixStream::pair().expect("socketpair");
        reader.set_nonblocking(true).expect("nonblocking");
        LIVE_RUNTIMES.fetch_add(1, Ordering::SeqCst);
        CREATED_RUNTIMES.fetch_add(1, Ordering::SeqCst);
        Self {
            counter: 0,
            state: QString::from("idle"),
            runtime: Some(runtime),
            writer: Some(writer),
            reader: Some(reader),
            model: Arc::default(),
            alive: Arc::new(AtomicBool::new(true)),
        }
    }
}

impl Drop for SpikeRust {
    fn drop(&mut self) {
        // From here on any callback that still runs is "late"; post() counts it.
        self.alive.store(false, Ordering::SeqCst);
        self.writer.take(); // EOF ends the reader task
        if let Some(rt) = self.runtime.take() {
            // Joins the worker threads; bounded so a stuck task cannot hang Quickshell.
            rt.shutdown_timeout(Duration::from_secs(2));
        }
        LIVE_RUNTIMES.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Counts a closure that never ran: refused by queue(), or discarded with its object.
struct Unrun(bool);
impl Drop for Unrun {
    fn drop(&mut self) {
        if !self.0 {
            DROPPED_UNRUN.fetch_add(1, Ordering::SeqCst);
        }
    }
}

/// Queues `f` onto the Qt thread that owns `target`, with bookkeeping.
/// Every attempt ends as exactly one of: ran, or dropped unrun (either refused
/// by queue() because the object is gone, or discarded by Qt with the object).
fn post<T, F>(target: &CxxQtThread<T>, alive: &Arc<AtomicBool>, f: F)
where
    T: Threading,
    F: FnOnce(Pin<&mut T>) + Send + 'static,
{
    let alive = alive.clone();
    ATTEMPTED.fetch_add(1, Ordering::SeqCst);
    let unrun = Unrun(false);
    let result = target.queue(move |obj| {
        // Bind the whole guard (not just the field) so it moves into the closure.
        let mut unrun = unrun;
        unrun.0 = true;
        if !alive.load(Ordering::SeqCst) {
            LATE.fetch_add(1, Ordering::SeqCst);
            return;
        }
        RAN.fetch_add(1, Ordering::SeqCst);
        f(obj);
    });
    if result.is_err() {
        REFUSED.fetch_add(1, Ordering::SeqCst);
    }
}

/// The async part, generic over the stream so it is unit-testable without Qt.
pub async fn read_lines<R: AsyncRead + Unpin>(stream: R, mut on_line: impl FnMut(String)) {
    let mut lines = BufReader::new(stream).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        on_line(line);
    }
}

impl cxx_qt::Initialize for Spike {
    fn initialize(mut self: Pin<&mut Self>) {
        let me = self.qt_thread();
        let alive = self.rust().alive.clone();
        let model = self.rust().model.clone();
        let reader = self.as_mut().rust_mut().reader.take().expect("reader");
        let rt = self.rust().runtime.as_ref().expect("runtime");
        rt.spawn(async move {
            let stream = tokio::net::UnixStream::from_std(reader).expect("tokio stream");
            read_lines(stream, |line| {
                let peers = parse(&line);
                if let Some(m) = model.lock().unwrap().clone() {
                    post(&m, &alive, move |m: Pin<&mut PeerModel>| m.apply(peers));
                }
                post(&me, &alive, move |mut s: Pin<&mut Spike>| {
                    s.as_mut().rust_mut().counter += 1;
                    s.as_mut().rust_mut().state = QString::from(line.as_str());
                    s.as_mut().counter_changed();
                    s.as_mut().state_changed();
                });
            })
            .await;
        });
    }
}

impl Spike {
    pub fn feed(&self, line: &QString) -> bool {
        let Some(mut w) = self.rust().writer.as_ref() else { return false };
        writeln!(w, "{line}").is_ok()
    }

    /// # Safety
    /// `model` must be a live PeerModel (QML passes one it owns) or null.
    pub unsafe fn attach(self: Pin<&mut Self>, model: *mut PeerModel) {
        let thread = model.as_ref().map(|m| m.qt_thread());
        *self.rust().model.lock().unwrap() = thread;
    }

    pub fn late_callbacks(&self) -> i32 {
        LATE.load(Ordering::SeqCst)
    }
    pub fn live_runtimes(&self) -> i32 {
        LIVE_RUNTIMES.load(Ordering::SeqCst)
    }
    pub fn dropped_callbacks(&self) -> i32 {
        DROPPED_UNRUN.load(Ordering::SeqCst)
    }
    pub fn attempted_callbacks(&self) -> i32 {
        ATTEMPTED.load(Ordering::SeqCst)
    }
    pub fn refused_callbacks(&self) -> i32 {
        REFUSED.load(Ordering::SeqCst)
    }
    pub fn created_runtimes(&self) -> i32 {
        CREATED_RUNTIMES.load(Ordering::SeqCst)
    }
    /// Threads named THREAD_NAME in this process (for the Quickshell procedure).
    pub fn tokio_threads(&self) -> i32 {
        thread_names().iter().filter(|n| n.starts_with(THREAD_NAME)).count() as i32
    }
    pub fn thread_count(&self) -> i32 {
        thread_names().len() as i32
    }
    pub fn ran_callbacks(&self) -> i32 {
        RAN.load(Ordering::SeqCst)
    }
}

pub(crate) fn thread_names() -> Vec<String> {
    std::fs::read_dir("/proc/self/task")
        .map(|d| {
            d.filter_map(|e| std::fs::read_to_string(e.ok()?.path().join("comm")).ok())
                .map(|s| s.trim().to_string())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn read_lines_delivers_each_line_and_stops_at_eof() {
        let (mut tx, rx) = tokio::io::duplex(64);
        let task = tokio::spawn(async move {
            let mut got = Vec::new();
            read_lines(rx, |l| got.push(l)).await;
            got
        });
        tokio::io::AsyncWriteExt::write_all(&mut tx, b"a=1\nb=0\n").await.unwrap();
        drop(tx);
        assert_eq!(task.await.unwrap(), vec!["a=1".to_string(), "b=0".to_string()]);
    }

    #[tokio::test(start_paused = true)]
    async fn paused_time_drives_an_interval_without_sleeping() {
        // Shows the time-control pattern Phase 1 will use: no wall-clock wait.
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        tick.tick().await; // immediate first tick
        let started = std::time::Instant::now();
        tokio::time::advance(Duration::from_secs(30)).await;
        tick.tick().await;
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
