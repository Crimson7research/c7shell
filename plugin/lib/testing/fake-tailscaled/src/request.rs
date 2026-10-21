//! A request as the fake received it.

use crate::server::ClientId;

/// One request, recorded in the order the fake framed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// The client that sent it.
    pub client: ClientId,
    /// Its position among every request the fake recorded, from 0.
    pub seq: usize,
    /// Exactly the bytes received: head, delimiter and body.
    pub raw: Vec<u8>,
    /// #286's shape: the head alone for a request without a body, the head,
    /// delimiter and body for one with a body.
    pub recorded: Vec<u8>,
    /// No scripted rule matched it, so the fake answered 404.
    pub unmatched: bool,
    head_len: usize,
    body_start: usize,
}

impl Request {
    pub fn new(client: ClientId, seq: usize, head: &[u8], delimiter: &[u8], body: &[u8]) -> Request {
        let raw = [head, delimiter, body].concat();
        let recorded = if body.is_empty() { head.to_vec() } else { raw.clone() };
        Request {
            client,
            seq,
            raw,
            recorded,
            unmatched: false,
            head_len: head.len(),
            body_start: head.len() + delimiter.len(),
        }
    }

    fn head(&self) -> &[u8] {
        &self.raw[..self.head_len]
    }

    fn request_line(&self) -> String {
        let head = self.head();
        let end = head.iter().position(|&b| b == b'\n').unwrap_or(head.len());
        let line = &head[..end];
        String::from_utf8_lossy(line.strip_suffix(b"\r").unwrap_or(line)).into_owned()
    }

    fn request_line_part(&self, n: usize) -> String {
        self.request_line().split(' ').nth(n).unwrap_or("").to_string()
    }

    /// The first word of the request line.
    pub fn method(&self) -> String {
        self.request_line_part(0)
    }

    /// The request target, query included.
    pub fn target(&self) -> String {
        self.request_line_part(1)
    }

    /// The target without its query.
    pub fn path(&self) -> String {
        let target = self.target();
        target.split('?').next().unwrap_or("").to_string()
    }

    pub fn version(&self) -> String {
        self.request_line_part(2)
    }

    /// The header lines after the request line, name and value, in order and
    /// with their case kept.
    pub fn headers(&self) -> Vec<(String, String)> {
        let head = String::from_utf8_lossy(self.head()).into_owned();
        head.split('\n')
            .skip(1)
            .map(|l| l.strip_suffix('\r').unwrap_or(l))
            .filter(|l| !l.is_empty())
            .map(|l| match l.split_once(':') {
                Some((name, value)) => (name.to_string(), value.trim().to_string()),
                None => (l.to_string(), String::new()),
            })
            .collect()
    }

    pub fn body(&self) -> &[u8] {
        &self.raw[self.body_start..]
    }
}

/// The body size a request head declares with `Content-Length`, or 0.
pub(crate) fn declared_body_size(head: &[u8]) -> usize {
    String::from_utf8_lossy(head)
        .split('\n')
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_parses_method_target_headers_and_body() {
        let r = Request::new(3, 7, b"PATCH /localapi/v0/prefs?x=1 HTTP/1.1\r\nHost: local-tailscaled.sock\r\ncontent-Type: application/json\r\nContent-Length: 4\r\n", b"\r\n\r\n", b"{}{}");
        assert_eq!(r.client, 3);
        assert_eq!(r.seq, 7);
        assert_eq!(r.raw, b"PATCH /localapi/v0/prefs?x=1 HTTP/1.1\r\nHost: local-tailscaled.sock\r\ncontent-Type: application/json\r\nContent-Length: 4\r\n\r\n\r\n{}{}".to_vec());
        // #286's shape: the whole message when there is a body.
        assert_eq!(r.recorded, r.raw);
        assert_eq!(r.method(), "PATCH");
        assert_eq!(r.target(), "/localapi/v0/prefs?x=1");
        assert_eq!(r.path(), "/localapi/v0/prefs");
        assert_eq!(r.version(), "HTTP/1.1");
        assert_eq!(
            r.headers(),
            vec![
                ("Host".to_string(), "local-tailscaled.sock".to_string()),
                ("content-Type".to_string(), "application/json".to_string()),
                ("Content-Length".to_string(), "4".to_string()),
            ]
        );
        assert_eq!(r.body(), b"{}{}");
        assert!(!r.unmatched);

        let g = Request::new(1, 0, b"GET /q HTTP/1.1", b"\r\n\r\n", b"");
        // Head only when there is no body; raw still holds the delimiter.
        assert_eq!(g.recorded, b"GET /q HTTP/1.1");
        assert_eq!(g.raw, b"GET /q HTTP/1.1\r\n\r\n");
        assert_eq!(g.path(), "/q");
        assert!(g.headers().is_empty());
        assert_eq!(g.body(), b"");

        let bare = Request::new(1, 0, b"ping", b"", b"");
        assert_eq!(bare.raw, b"ping");
        assert_eq!(bare.recorded, b"ping");
        assert_eq!(bare.method(), "ping");
        assert_eq!(bare.target(), "");
        assert_eq!(bare.version(), "");
    }
}
