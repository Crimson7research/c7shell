//! The fake's scripted half: answering from a [`crate::Script`], resuming
//! parked replies, pushing to watch streams and completing held requests.

use crate::client::Parked;
use crate::reply::{watch_chunk, Encoded};
use crate::request::Request;
use crate::script::Action;
use crate::server::{AfterReply, ClientId, State};

impl State {
    /// Answers `request` from the script; a request no rule matches gets 404
    /// and is flagged.
    pub(crate) fn answer_from_script(&mut self, id: ClientId, mut request: Request) {
        let action = self.script.as_mut().unwrap().answer(&request);
        if action.is_none() {
            request.unmatched = true;
        }
        self.requests.push(request);
        let client = self.client_mut(id).unwrap();
        match action {
            Some(Action::Reply(Encoded { bytes, splits, then })) => client.write_until_split(bytes, splits, then),
            Some(Action::Hold) => client.held = true,
            Some(Action::Stream(Encoded { bytes, .. })) => {
                client.watch = true;
                client.write(&bytes);
            }
            None => {
                client.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                client.close();
            }
        }
    }

    /// Writes the next part of every reply parked on `label`.
    pub(crate) fn resume(&mut self, label: &str) -> usize {
        let mut resumed = 0;
        for c in self.clients.iter_mut().filter(|c| c.connected && c.parked.as_ref().is_some_and(|p| p.label == label))
        {
            let Parked { rest, splits, then, .. } = c.parked.take().unwrap();
            c.write_until_split(rest, splits, then);
            resumed += 1;
        }
        resumed
    }

    /// Writes `line` as one chunk to every watch stream that takes pushes.
    pub(crate) fn push_watch_line(&mut self, line: &[u8]) -> usize {
        let chunk = watch_chunk(line);
        self.clients
            .iter_mut()
            .filter(|c| c.watch && c.takes_pushes())
            .map(|c| c.write(&chunk))
            .filter(|&ok| ok)
            .count()
    }

    /// Writes `bytes` to every client that takes pushes; returns how many
    /// took them.
    pub(crate) fn push(&mut self, bytes: &[u8]) -> usize {
        self.clients.iter_mut().filter(|c| c.takes_pushes()).map(|c| c.write(bytes)).filter(|&ok| ok).count()
    }

    /// Writes `reply` to every held client and releases it.
    pub(crate) fn complete_held(&mut self, reply: &[u8]) -> usize {
        let after = self.after;
        let mut reached = 0;
        for c in self.clients.iter_mut().filter(|c| c.held) {
            c.held = false;
            if c.write(reply) {
                reached += 1;
            }
            if after == AfterReply::CloseAfterReply {
                c.close();
            }
        }
        reached
    }
}
