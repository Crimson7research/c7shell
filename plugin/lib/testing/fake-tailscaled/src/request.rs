//! A request as the fake received it.

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
