//! One accepted client of the fake: what it reports, and how the fake
//! writes to it and closes it.

use std::io::{ErrorKind, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;

use crate::reply::Then;
use crate::server::ClientId;

/// What the fake reports about one client, for the barriers (R-FAKE-07).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientReport {
    pub id: ClientId,
    pub connected: bool,
    /// Bytes consumed from the client, whether or not they form a request.
    pub received: usize,
    /// Bytes written to the client: replies, completions and pushes.
    pub written: usize,
    pub held: bool,
    /// A scripted reply is part-written and waits for its release.
    pub parked: bool,
    /// A scripted watch stream: watch lines reach it.
    pub stream: bool,
}

/// The rest of a split reply, waiting for `label`.
pub(crate) struct Parked {
    pub(crate) label: String,
    pub(crate) rest: Vec<u8>,
    /// Later splits, as offsets into `rest`.
    pub(crate) splits: Vec<(usize, String)>,
    pub(crate) then: Then,
}

/// One accepted client.
pub(crate) struct ClientEntry {
    pub(crate) id: ClientId,
    pub(crate) stream: Arc<UnixStream>,
    pub(crate) connected: bool,
    /// The fake has closed it: nothing it sends afterwards is a request.
    pub(crate) closed: bool,
    pub(crate) received: usize,
    pub(crate) written: usize,
    /// Its request is held: recorded, unanswered, connected.
    pub(crate) held: bool,
    pub(crate) parked: Option<Parked>,
    pub(crate) watch: bool,
    pub(crate) pending: Vec<u8>,
    /// Writes that failed through the fake's fault, in order.
    pub(crate) faults: Vec<String>,
}

impl ClientEntry {
    /// Writes `bytes` whole; false when the client cannot take them.
    pub(crate) fn write(&mut self, bytes: &[u8]) -> bool {
        if !self.connected || self.closed {
            return false;
        }
        match (&*self.stream).write_all(bytes) {
            Ok(()) => {
                self.written += bytes.len();
                true
            }
            Err(e) => {
                self.faults.extend(write_fault(self.id, &e));
                false
            }
        }
    }

    /// Takes pushed bytes: connected, not closed, not held, not parked.
    pub(crate) fn takes_pushes(&self) -> bool {
        self.connected && !self.closed && !self.held && self.parked.is_none()
    }

    /// Writes `bytes` up to the first of `splits` and parks the rest, or
    /// writes it all and does what `then` says.
    pub(crate) fn write_until_split(&mut self, mut bytes: Vec<u8>, mut splits: Vec<(usize, String)>, then: Then) {
        if splits.is_empty() {
            if then != Then::CloseWithoutReply {
                self.write(&bytes);
            }
            if then != Then::KeepOpen {
                self.close();
            }
            return;
        }
        let (at, label) = splits.remove(0);
        let rest = bytes.split_off(at);
        self.write(&bytes);
        let splits = splits.into_iter().map(|(o, l)| (o - at, l)).collect();
        self.parked = Some(Parked { label, rest, splits, then });
    }

    pub(crate) fn close(&mut self) {
        self.closed = true;
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

/// The fault a failed write is, if the fake is to blame: a write that timed
/// out because the client did not drain it. A peer that went away (a broken
/// pipe, a reset) is the client's doing, not a fault.
fn write_fault(id: ClientId, e: &std::io::Error) -> Option<String> {
    matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
        .then(|| format!("a write to client {id} timed out ({e}): the client did not drain it"))
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};

    use super::write_fault;

    #[test]
    fn a_timed_out_write_is_the_fakes_fault_and_a_peer_gone_is_not() {
        for kind in [ErrorKind::WouldBlock, ErrorKind::TimedOut] {
            let fault = write_fault(3, &Error::from(kind));
            assert!(fault.as_deref().is_some_and(|f| f.starts_with("a write to client 3 timed out")), "{fault:?}");
        }
        for kind in [ErrorKind::BrokenPipe, ErrorKind::ConnectionReset, ErrorKind::NotConnected] {
            assert_eq!(write_fault(3, &Error::from(kind)), None, "{kind:?}");
        }
    }
}
