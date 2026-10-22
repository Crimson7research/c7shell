//! The socket server core: one Unix socket in the test's private directory,
//! an acceptor thread and one reader thread per client.
//!
//! R-FAKE-05 (bind and refuse) and R-FAKE-06 (the behaviour the fake had
//! before #286) specify it. It re-implements the semantics of #286's
//! `plugin/lib/testing/fakesocketserver.{h,cpp}` from those requirements.

use std::fs;
use std::net::Shutdown;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::client::{ClientEntry, ClientReport};
use crate::listener::{accept_loop, bind};
use crate::request::{declared_body_size, Request};
use crate::script::{Compiled, Script};

/// The bound on every wait in the fake and its tests. A passing test never
/// reaches it; it only turns a hang into a failure. Nothing asserts on time.
pub const FAILURE_BOUND: Duration = Duration::from_secs(10);

/// The largest reply, stream head, push or completion a scenario may
/// script. The fake writes with a blocking write, a reply under its lock and
/// a push on the caller's thread, which in the harness is the Qt thread the
/// client reads on. A write the client cannot drain meanwhile must fit an
/// unread Unix socket buffer, which holds about 228 KiB in one write with
/// Linux's default 208 KiB `wmem_default`. Many small writes fill it much
/// sooner (about 27 KiB in 100-byte writes), so a scenario pumps the event
/// loop between long runs of pushes.
pub const MAX_WRITE: usize = 128 * 1024;

/// A client's id: its position in accept order, counted from 1.
pub type ClientId = usize;

/// Answers one request: the bytes to write back, or None to write nothing.
/// It runs under the fake's lock, so it must not call back into the fake.
pub type Handler = Box<dyn Fn(&Request) -> Option<Vec<u8>> + Send + Sync>;

/// What happens to a client after a handler reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AfterReply {
    CloseAfterReply,
    KeepOpen,
}

/// Everything the fake knows, behind one lock. Every change is followed by
/// a `notify_all` on the fake's condition variable.
pub struct State {
    pub(crate) clients: Vec<ClientEntry>,
    pub(crate) requests: Vec<Request>,
    handler: Option<Handler>,
    pub(crate) after: AfterReply,
    delimiter: Option<Vec<u8>>,
    hold_fragment: Option<Vec<u8>>,
    pub(crate) disconnects: usize,
    pub(crate) script: Option<Compiled>,
    /// Failures inside the fake that are not a client's doing.
    pub(crate) faults: Vec<String>,
    pub(crate) write_timeout: Duration,
}

impl Default for State {
    fn default() -> State {
        State {
            clients: Vec::new(),
            requests: Vec::new(),
            handler: None,
            after: AfterReply::CloseAfterReply,
            delimiter: None,
            hold_fragment: None,
            disconnects: 0,
            script: None,
            faults: Vec::new(),
            write_timeout: FAILURE_BOUND,
        }
    }
}

impl State {
    /// Every request recorded, in order.
    pub fn requests(&self) -> &[Request] {
        &self.requests
    }

    /// The bytes received from client `id` so far, framed or not.
    pub fn received(&self, id: ClientId) -> usize {
        self.client(id).map_or(0, |c| c.received)
    }

    /// The bytes written to client `id` so far: replies, completions, pushes.
    pub fn written(&self, id: ClientId) -> usize {
        self.client(id).map_or(0, |c| c.written)
    }

    /// Every client accepted, connected or not, in accept order.
    pub fn clients(&self) -> Vec<ClientReport> {
        self.clients
            .iter()
            .map(|c| ClientReport {
                id: c.id,
                connected: c.connected,
                received: c.received,
                written: c.written,
                held: c.held && c.connected,
                parked: c.parked.is_some() && c.connected,
                stream: c.watch,
            })
            .collect()
    }

    /// Every client accepted since the fake started. It never drops.
    pub fn accepted_total(&self) -> usize {
        self.clients.len()
    }

    /// The disconnects the fake has handled.
    pub fn disconnects(&self) -> usize {
        self.disconnects
    }

    /// The clients connected now.
    pub fn connected_count(&self) -> usize {
        self.clients.iter().filter(|c| c.connected).count()
    }

    /// The fake's own failures: an accept that failed, then each write that
    /// timed out, by client. A test that sees one cannot blame the client.
    pub fn faults(&self) -> Vec<String> {
        self.faults.iter().chain(self.clients.iter().flat_map(|c| &c.faults)).cloned().collect()
    }

    /// The held client whose last request contains `fragment`.
    pub fn client_holding(&self, fragment: &[u8]) -> Option<ClientId> {
        self.clients.iter().filter(|c| c.connected && c.held).map(|c| c.id).find(|&id| {
            self.requests.iter().rev().find(|r| r.client == id).is_some_and(|r| find(&r.recorded, fragment).is_some())
        })
    }

    /// The requests held now.
    pub fn held_count(&self) -> usize {
        self.clients.iter().filter(|c| c.connected && c.held).count()
    }

    pub(crate) fn client(&self, id: ClientId) -> Option<&ClientEntry> {
        self.clients.iter().find(|c| c.id == id)
    }

    pub(crate) fn client_mut(&mut self, id: ClientId) -> Option<&mut ClientEntry> {
        self.clients.iter_mut().find(|c| c.id == id)
    }

    /// Takes `bytes` from client `id`, then frames and answers what is whole.
    pub(crate) fn receive(&mut self, id: ClientId, bytes: &[u8]) {
        let Some(client) = self.client_mut(id) else { return };
        client.received += bytes.len();
        if client.closed {
            return;
        }
        let Some(delimiter) = self.delimiter.clone() else {
            // Without a delimiter a request is whatever one read returned.
            self.answer(id, Request::new(id, self.requests.len(), bytes, b"", b""));
            return;
        };
        self.client_mut(id).unwrap().pending.extend_from_slice(bytes);
        loop {
            let client = self.client_mut(id).unwrap();
            if client.closed {
                client.pending.clear();
                return;
            }
            let Some(at) = find(&client.pending, &delimiter) else { return };
            let body = declared_body_size(&client.pending[..at]);
            let end = at + delimiter.len() + body;
            if client.pending.len() < end {
                return;
            }
            let message: Vec<u8> = client.pending.drain(..end).collect();
            let request =
                Request::new(id, self.requests.len(), &message[..at], &delimiter, &message[at + delimiter.len()..]);
            self.answer(id, request);
        }
    }

    /// Records `request`, then holds it or answers it with the handler.
    fn answer(&mut self, id: ClientId, request: Request) {
        let held = matches!(&self.hold_fragment, Some(f) if find(&request.recorded, f).is_some());
        if held {
            self.requests.push(request);
            self.hold_fragment = None;
            self.client_mut(id).unwrap().held = true;
            return;
        }
        if self.script.is_some() {
            self.answer_from_script(id, request);
            return;
        }
        let reply = self.handler.as_ref().and_then(|h| h(&request));
        self.requests.push(request);
        let after = self.after;
        let client = self.client_mut(id).unwrap();
        if let Some(reply) = reply {
            client.write(&reply);
            if after == AfterReply::CloseAfterReply {
                client.close();
            }
        }
    }
}

/// The first position of `needle` in `hay`.
fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

pub(crate) struct Shared {
    pub(crate) state: Mutex<State>,
    pub(crate) changed: Condvar,
    pub(crate) closing: AtomicBool,
    pub(crate) readers: Mutex<Vec<JoinHandle<()>>>,
}

impl Shared {
    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        // A panicking handler poisons the lock; the state is still sound.
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// A fake tailscaled listening on a Unix socket.
pub struct Fake {
    path: PathBuf,
    error: Option<String>,
    inode: Option<u64>,
    shared: Arc<Shared>,
    acceptor: Mutex<Option<JoinHandle<()>>>,
}

impl Fake {
    /// Starts listening at `path`. It never panics on a bind failure: it
    /// reports it through [`Fake::is_listening`] and [`Fake::error`].
    ///
    /// It refuses anything already at `path`, a live socket included, and
    /// creates missing parent directories with mode 0700. The socket gets
    /// mode 0600.
    pub fn start(path: impl Into<PathBuf>) -> Fake {
        let path = path.into();
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            closing: AtomicBool::new(false),
            readers: Mutex::new(Vec::new()),
        });
        let mut fake = Fake { path, error: None, inode: None, shared, acceptor: Mutex::new(None) };
        match bind(&fake.path) {
            Ok((listener, inode)) => {
                fake.inode = Some(inode);
                let shared = fake.shared.clone();
                *fake.acceptor.get_mut().unwrap_or_else(|e| e.into_inner()) =
                    Some(std::thread::spawn(move || accept_loop(listener, shared)));
            }
            Err(e) => fake.error = Some(e),
        }
        fake
    }

    pub fn is_listening(&self) -> bool {
        self.acceptor.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// Why it is not listening, or None when it is.
    pub fn error(&self) -> Option<String> {
        self.error.clone()
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Answers every request with `handler`, then closes the client or keeps
    /// it open. With a `delimiter`, a request is what comes before each
    /// delimiter, plus the body its `Content-Length` declares, however the
    /// reads split it. Without one, a request is whatever one read returns.
    pub fn on_request(&self, handler: Handler, after: AfterReply, delimiter: Option<&[u8]>) {
        let mut state = self.shared.lock();
        state.handler = Some(handler);
        state.after = after;
        state.delimiter = delimiter.filter(|d| !d.is_empty()).map(<[u8]>::to_vec);
    }

    /// Sends `line` and a newline to every connected client that is not
    /// held; returns how many took it.
    pub fn push_line(&self, line: &[u8]) -> usize {
        self.push_chunk(&[line, b"\n"].concat())
    }

    /// Sends exactly `bytes` to every connected client that is not held;
    /// returns how many took them.
    pub fn push_chunk(&self, bytes: &[u8]) -> usize {
        self.locked(|s| s.push(bytes))
    }

    /// Sends `bytes` to client `id` alone, held or not; false when it is not
    /// connected.
    pub fn push_to(&self, id: ClientId, bytes: &[u8]) -> bool {
        self.locked(|s| s.client_mut(id).is_some_and(|c| c.write(bytes)))
    }

    /// Holds the next request whose recorded bytes contain `fragment`:
    /// recorded, not answered, left connected and skipped by pushes. One
    /// request per call; a further call while one is held holds another.
    pub fn hold_next(&self, fragment: &[u8]) {
        self.locked(|s| s.hold_fragment = Some(fragment.to_vec()));
    }

    /// Writes `reply` to every request held now and releases it (closing it
    /// unless the fake keeps clients open); returns how many it reached. A
    /// hold armed but not yet used stays armed.
    pub fn complete_held(&self, reply: &[u8]) -> usize {
        self.locked(|s| s.complete_held(reply))
    }

    /// The requests held now.
    pub fn held_count(&self) -> usize {
        self.shared.lock().held_count()
    }

    /// The fragment a [`Fake::hold_next`] armed that no request has used yet.
    pub fn armed_hold(&self) -> Option<Vec<u8>> {
        self.shared.lock().hold_fragment.clone()
    }

    /// Closes client `id` alone, as tailscaled going away with that one
    /// request in flight would; the fake keeps listening and serving the
    /// others. False when that client is unknown or no longer connected.
    pub fn close_client(&self, id: ClientId) -> bool {
        self.locked(|s| match s.client_mut(id) {
            Some(c) if c.connected && !c.closed => {
                c.close();
                true
            }
            _ => false,
        })
    }

    /// The held client whose last request contains `fragment`.
    pub fn client_holding(&self, fragment: &[u8]) -> Option<ClientId> {
        self.shared.lock().client_holding(fragment)
    }

    /// Every client accepted, in accept order (R-FAKE-07).
    pub fn clients(&self) -> Vec<ClientReport> {
        self.shared.lock().clients()
    }

    /// The clients connected now.
    pub fn connected_count(&self) -> usize {
        self.shared.lock().connected_count()
    }

    /// Every client accepted since the fake started.
    pub fn accepted_total(&self) -> usize {
        self.shared.lock().accepted_total()
    }

    /// The disconnects the fake has handled.
    pub fn disconnects(&self) -> usize {
        self.shared.lock().disconnects()
    }

    /// The fake's own failures ([`State::faults`]).
    pub fn faults(&self) -> Vec<String> {
        self.shared.lock().faults()
    }

    /// Bounds each write to a client from now on, [`FAILURE_BOUND`] by
    /// default. A write that reaches it is a fault.
    pub fn set_write_timeout(&self, bound: Duration) {
        self.locked(|s| {
            s.write_timeout = bound;
            for c in &s.clients {
                let _ = c.stream.set_write_timeout(Some(bound));
            }
        });
    }

    /// Runs `f` on the state, then wakes every waiter.
    fn locked<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        let value = f(&mut self.shared.lock());
        self.shared.changed.notify_all();
        value
    }

    /// Answers from `script` from now on: requests are framed on CRLFCRLF
    /// with their declared bodies, each rule replies, holds or opens a watch
    /// stream, and a request no rule matches gets 404 and is flagged
    /// ([`Request::unmatched`]). A held request is completed with
    /// [`Fake::complete_held`], which then closes it. Fails, changing
    /// nothing, when a rule cannot be encoded.
    pub fn set_script(&self, script: Script) -> Result<(), String> {
        let compiled = script.compile()?;
        self.locked(|s| {
            s.script = Some(compiled);
            s.after = AfterReply::CloseAfterReply;
            s.delimiter = Some(b"\r\n\r\n".to_vec());
        });
        Ok(())
    }

    /// Writes `line` and a newline as one chunk, `<hex length>\r\n<line>\n\r\n`,
    /// to every scripted watch stream not held or parked; returns how many.
    pub fn push_watch_line(&self, line: &[u8]) -> usize {
        self.locked(|s| s.push_watch_line(line))
    }

    /// Writes the next part of every reply parked on `label`, up to its next
    /// split or its end; returns how many it resumed.
    pub fn resume(&self, label: &str) -> usize {
        self.locked(|s| s.resume(label))
    }

    /// Every request recorded, in order.
    pub fn requests(&self) -> Vec<Request> {
        self.shared.lock().requests.clone()
    }

    /// Waits until `f` returns Some and returns its value. Panics, naming
    /// `what`, at FAILURE_BOUND.
    pub fn wait_until<T>(&self, what: &str, f: impl FnMut(&State) -> Option<T>) -> T {
        self.wait_until_within(what, FAILURE_BOUND, f)
    }

    /// [`Fake::wait_until`] with another bound.
    pub fn wait_until_within<T>(&self, what: &str, bound: Duration, f: impl FnMut(&State) -> Option<T>) -> T {
        wait_for(&self.shared, what, bound, f).unwrap_or_else(|e| panic!("{e}"))
    }

    /// Like [`Fake::wait_until`], but returns the failure instead of panicking.
    pub fn wait_for<T>(&self, what: &str, f: impl FnMut(&State) -> Option<T>) -> Result<T, String> {
        wait_for(&self.shared, what, FAILURE_BOUND, f)
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.stop();
    }
}

impl Fake {
    /// Stops accepting, disconnects every client and removes the socket it
    /// bound, if the path still holds that socket: tailscaled went away.
    /// What it recorded stays readable. Stopping again does nothing.
    pub fn stop(&self) {
        let Some(acceptor) = self.acceptor.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
        self.shared.closing.store(true, Ordering::SeqCst);
        // Wake the blocking accept, but only through this fake's own socket:
        // a path that is gone or now holds another socket cannot reach it,
        // and connecting to that one would wake someone else's acceptor and
        // leave the join waiting for ever. Such a thread is left to end with
        // the process.
        if self.still_bound() && UnixStream::connect(&self.path).is_ok() {
            let _ = acceptor.join();
        }
        for c in self.shared.lock().clients.iter() {
            let _ = c.stream.shutdown(Shutdown::Both);
        }
        let readers = std::mem::take(&mut *self.shared.readers.lock().unwrap_or_else(|e| e.into_inner()));
        for r in readers {
            let _ = r.join();
        }
        if self.still_bound() {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Fake {
    /// The path still holds the socket this fake bound.
    fn still_bound(&self) -> bool {
        matches!((self.inode, fs::symlink_metadata(&self.path)), (Some(inode), Ok(meta)) if meta.ino() == inode)
    }
}

/// Waits on the fake's condition variable until `f` returns Some, or fails
/// naming `what` once `bound` has passed.
fn wait_for<T>(
    shared: &Shared,
    what: &str,
    bound: Duration,
    mut f: impl FnMut(&State) -> Option<T>,
) -> Result<T, String> {
    let deadline = Instant::now() + bound;
    let mut state = shared.lock();
    loop {
        if let Some(v) = f(&state) {
            return Ok(v);
        }
        let now = Instant::now();
        if now >= deadline {
            return Err(format!("the fake never reached: {what}"));
        }
        state = shared.changed.wait_timeout(state, deadline - now).unwrap_or_else(|e| e.into_inner()).0;
    }
}
