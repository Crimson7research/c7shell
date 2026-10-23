//! The `request_parts` expectation: a recorded request checked by its
//! start, the headers it must carry and its body read as JSON, so neither
//! header order nor JSON key order is pinned.

use serde::Deserialize;
use serde_json::Value;

use crate::bytes::Bytes;
use crate::request::Request;
use crate::script::Match;

/// Every recorded request that `match`es:
///
/// - starts with `starts_with`;
/// - has its head end in CRLFCRLF;
/// - carries each of `headers` (a name, compared without case, and its
///   exact value) once;
/// - with `body_json`, has a body that parses as JSON equal to it, and a
///   `Content-Length` equal to the body's byte length.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestParts {
    #[serde(rename = "match")]
    pub matcher: Match,
    pub starts_with: Bytes,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    pub body_json: Option<Value>,
}

impl RequestParts {
    pub fn validate(&self) -> Result<(), String> {
        self.matcher.validate()?;
        match self.headers.iter().position(|(name, _)| name.trim().is_empty()) {
            Some(i) => Err(format!("headers[{i}]: empty name")),
            None => Ok(()),
        }
    }

    /// Why `r` lacks one of the parts, or `Ok` when it has them all.
    pub fn check(&self, r: &Request) -> Result<(), String> {
        if !r.raw.starts_with(&self.starts_with.0) {
            return Err("it starts otherwise".into());
        }
        let head_and_delimiter = &r.raw[..r.raw.len() - r.body().len()];
        if !head_and_delimiter.ends_with(b"\r\n\r\n") {
            return Err("its head does not end in CRLFCRLF".into());
        }
        let headers = r.headers();
        let named = |name: &str| -> Vec<&str> {
            headers.iter().filter(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str()).collect()
        };
        for (name, value) in &self.headers {
            let found = named(name);
            if found != [value.as_str()] {
                return Err(format!("header {name}: {found:?}, not [{value:?}]"));
            }
        }
        let Some(want) = &self.body_json else { return Ok(()) };
        let length = named("content-length");
        if length != [r.body().len().to_string().as_str()] {
            return Err(format!("Content-Length {length:?} for a body of {} bytes", r.body().len()));
        }
        match serde_json::from_slice::<Value>(r.body()) {
            Ok(got) if got == *want => Ok(()),
            Ok(got) => Err(format!("body {got}")),
            Err(e) => Err(format!("body is not JSON: {e}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const HEAD: &[u8] = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nHost: local-tailscaled.sock\r\nContent-Type: application/json\r\nContent-Length: 36";
    const BODY: &[u8] = b"{\"RouteAll\":true,\"RouteAllSet\":true}";

    fn parts(headers: &[(&str, &str)], body_json: Option<Value>) -> RequestParts {
        RequestParts {
            matcher: Match { method: "PATCH".into(), target: Some("/localapi/v0/prefs".into()), path: None },
            starts_with: Bytes(b"PATCH /localapi/v0/prefs HTTP/1.1\r\n".to_vec()),
            headers: headers.iter().map(|(n, v)| (n.to_string(), v.to_string())).collect(),
            body_json,
        }
    }

    fn patch(head: &[u8], delimiter: &[u8], body: &[u8]) -> Request {
        Request::new(1, 0, head, delimiter, body)
    }

    #[test]
    fn it_holds_whatever_the_header_and_key_order() {
        let want = json!({ "RouteAllSet": true, "RouteAll": true });
        let p = parts(&[("content-length", "36"), ("HOST", "local-tailscaled.sock")], Some(want));
        assert_eq!(p.check(&patch(HEAD, b"\r\n\r\n", BODY)), Ok(()));
        let reordered = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nContent-Length: 36\r\nHost: local-tailscaled.sock";
        assert_eq!(p.check(&patch(reordered, b"\r\n\r\n", b"{\"RouteAllSet\":true,\"RouteAll\":true}")), Ok(()));
    }

    #[test]
    fn it_names_the_part_that_differs() {
        let r = patch(HEAD, b"\r\n\r\n", BODY);
        let mut other = parts(&[], None);
        other.starts_with = Bytes(b"GET ".to_vec());
        assert_eq!(other.check(&r), Err("it starts otherwise".into()));
        assert!(parts(&[("Content-Type", "text/plain")], None).check(&r).unwrap_err().contains("Content-Type"));
        assert!(parts(&[("X-Absent", "1")], None).check(&r).unwrap_err().contains("X-Absent: []"));
        let wrong = parts(&[], Some(json!({ "RouteAll": false, "RouteAllSet": true })));
        assert!(wrong.check(&r).unwrap_err().starts_with("body {"));
        let not_json = patch(HEAD, b"\r\n\r\n", b"not json, but thirty-six bytes long.");
        assert!(parts(&[], Some(json!({}))).check(&not_json).unwrap_err().starts_with("body is not JSON"));
    }

    #[test]
    fn it_wants_crlfcrlf_and_a_length_that_is_the_bodys_own() {
        let want = Some(json!({ "RouteAll": true, "RouteAllSet": true }));
        let bare_lf = patch(HEAD, b"\n\n", BODY);
        assert_eq!(parts(&[], None).check(&bare_lf), Err("its head does not end in CRLFCRLF".into()));
        let short = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nHost: local-tailscaled.sock\r\nContent-Length: 35";
        let e = parts(&[], want.clone()).check(&patch(short, b"\r\n\r\n", BODY)).unwrap_err();
        assert!(e.contains("Content-Length [\"35\"]"), "{e}");
        let none = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nHost: local-tailscaled.sock";
        let e = parts(&[], want).check(&patch(none, b"\r\n\r\n", BODY)).unwrap_err();
        assert!(e.contains("Content-Length []"), "{e}");
        let twice = b"PATCH /localapi/v0/prefs HTTP/1.1\r\nHost: a\r\nHost: a";
        assert!(parts(&[("Host", "a")], None).check(&patch(twice, b"\r\n\r\n", b"")).is_err());
    }

    #[test]
    fn it_validates_its_match_and_header_names() {
        assert_eq!(parts(&[("Host", "x")], None).validate(), Ok(()));
        assert_eq!(parts(&[("Host", "x"), (" ", "y")], None).validate(), Err("headers[1]: empty name".into()));
        let mut both = parts(&[], None);
        both.matcher.path = Some("/localapi/v0/prefs".into());
        assert!(both.validate().unwrap_err().starts_with("match"));
    }
}
