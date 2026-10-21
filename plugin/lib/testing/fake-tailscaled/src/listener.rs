//! The fake's socket: binding it, the acceptor thread and one reader
//! thread per client.

use std::fs::{self, DirBuilder};
use std::io::{ErrorKind, Read};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::client::ClientEntry;
use crate::server::{ClientId, Shared};

/// Binds `path` and returns the listener and the socket's inode.
pub(crate) fn bind(path: &Path) -> Result<(UnixListener, u64), String> {
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

pub(crate) fn accept_loop(listener: UnixListener, shared: Arc<Shared>) {
    loop {
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => {
                if !shared.closing.load(Ordering::SeqCst) {
                    shared.lock().faults.push(format!("accept() failed, so the fake stopped accepting: {e}"));
                    shared.changed.notify_all();
                }
                return;
            }
        };
        if shared.closing.load(Ordering::SeqCst) {
            return;
        }
        let stream = Arc::new(stream);
        let id = {
            let mut state = shared.lock();
            // A stuck peer turns into a failed write, not a hung fake.
            let _ = stream.set_write_timeout(Some(state.write_timeout));
            let id = state.clients.len() + 1;
            state.clients.push(ClientEntry {
                id,
                stream: stream.clone(),
                connected: true,
                closed: false,
                received: 0,
                written: 0,
                held: false,
                parked: None,
                watch: false,
                pending: Vec::new(),
                faults: Vec::new(),
            });
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
            Ok(n) => {
                shared.lock().receive(id, &buf[..n]);
                shared.changed.notify_all();
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    {
        let mut state = shared.lock();
        if let Some(c) = state.clients.iter_mut().find(|c| c.id == id) {
            c.connected = false;
            c.held = false;
            c.parked = None;
            c.pending.clear();
        }
        state.disconnects += 1;
    }
    shared.changed.notify_all();
}
