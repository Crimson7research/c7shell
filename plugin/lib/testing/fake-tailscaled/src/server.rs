//! The socket server core: one Unix socket in the test's private directory,
//! an acceptor thread and one reader thread per client.
//!
//! R-FAKE-05 (bind and refuse) and R-FAKE-06 (the behaviour the fake had
//! before #286) specify it. It re-implements the semantics of #286's
//! `plugin/lib/testing/fakesocketserver.{h,cpp}` from those requirements.

use std::fs::{self, DirBuilder};
use std::io::{ErrorKind, Read};
use std::net::Shutdown;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

/// The bound on every wait in the fake and its tests. A passing test never
/// reaches it; it only turns a hang into a failure. Nothing asserts on time.
pub const FAILURE_BOUND: Duration = Duration::from_secs(10);

/// A client's id: its position in accept order, counted from 1.
pub type ClientId = usize;

/// One accepted client.
pub(crate) struct ClientEntry {
    pub(crate) id: ClientId,
    pub(crate) stream: Arc<UnixStream>,
    pub(crate) connected: bool,
}

/// Everything the fake knows, behind one lock. Every change is followed by
/// a `notify_all` on the fake's condition variable.
#[derive(Default)]
pub struct State {
    pub(crate) clients: Vec<ClientEntry>,
}

pub(crate) struct Shared {
    pub(crate) state: Mutex<State>,
    pub(crate) changed: Condvar,
    closing: AtomicBool,
    readers: Mutex<Vec<JoinHandle<()>>>,
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
    acceptor: Option<JoinHandle<()>>,
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
        let mut fake = Fake { path, error: None, inode: None, shared, acceptor: None };
        match bind(&fake.path) {
            Ok((listener, inode)) => {
                fake.inode = Some(inode);
                let shared = fake.shared.clone();
                fake.acceptor = Some(std::thread::spawn(move || accept_loop(listener, shared)));
            }
            Err(e) => fake.error = Some(e),
        }
        fake
    }

    pub fn is_listening(&self) -> bool {
        self.acceptor.is_some()
    }

    /// Why it is not listening, or None when it is.
    pub fn error(&self) -> Option<String> {
        self.error.clone()
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Binds `path` and returns the listener and the socket's inode.
fn bind(path: &Path) -> Result<(UnixListener, u64), String> {
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)
        .map_err(|e| format!("cannot create the directory for {}: {e}", path.display()))?;
    // Binding never replaces what is there: that could be another server's
    // live socket. A dangling symlink counts as taken too.
    if fs::symlink_metadata(path).is_ok() {
        return Err(format!("{} already exists", path.display()));
    }
    let listener = UnixListener::bind(path).map_err(|e| format!("cannot listen on {}: {e}", path.display()))?;
    let set_mode = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    let inode = fs::symlink_metadata(path).map(|m| m.ino());
    match (set_mode, inode) {
        (Ok(()), Ok(inode)) => Ok((listener, inode)),
        (Err(e), _) | (_, Err(e)) => {
            let _ = fs::remove_file(path);
            Err(format!("cannot make {} private: {e}", path.display()))
        }
    }
}

fn accept_loop(listener: UnixListener, shared: Arc<Shared>) {
    loop {
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        if shared.closing.load(Ordering::SeqCst) {
            return;
        }
        // A stuck peer turns into a failed write, not a hung fake.
        let _ = stream.set_write_timeout(Some(FAILURE_BOUND));
        let stream = Arc::new(stream);
        let id = {
            let mut state = shared.lock();
            let id = state.clients.len() + 1;
            state.clients.push(ClientEntry { id, stream: stream.clone(), connected: true });
            id
        };
        shared.changed.notify_all();
        let reader_shared = shared.clone();
        let handle = std::thread::spawn(move || read_loop(id, stream, reader_shared));
        shared.readers.lock().unwrap_or_else(|e| e.into_inner()).push(handle);
    }
}

fn read_loop(id: ClientId, stream: Arc<UnixStream>, shared: Arc<Shared>) {
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match (&*stream).read(&mut buf) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    {
        let mut state = shared.lock();
        if let Some(c) = state.clients.iter_mut().find(|c| c.id == id) {
            c.connected = false;
        }
    }
    shared.changed.notify_all();
}

impl Drop for Fake {
    /// Stops accepting, disconnects every client and removes the socket it
    /// bound, if the path still holds that socket.
    fn drop(&mut self) {
        let Some(acceptor) = self.acceptor.take() else { return };
        self.shared.closing.store(true, Ordering::SeqCst);
        // Wake the blocking accept. If the path is gone, nothing can wake it,
        // so the thread is left to end with the process.
        if UnixStream::connect(&self.path).is_ok() {
            let _ = acceptor.join();
        }
        for c in self.shared.lock().clients.iter() {
            let _ = c.stream.shutdown(Shutdown::Both);
        }
        let readers = std::mem::take(&mut *self.shared.readers.lock().unwrap_or_else(|e| e.into_inner()));
        for r in readers {
            let _ = r.join();
        }
        if let (Some(inode), Ok(meta)) = (self.inode, fs::symlink_metadata(&self.path)) {
            if meta.ino() == inode {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}
