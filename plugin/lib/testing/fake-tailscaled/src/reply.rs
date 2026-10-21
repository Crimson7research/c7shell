//! The HTTP reply a scripted rule sends: a pure function from a
//! [`ReplySpec`] to its bytes and the points where it waits for a release.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer};
use serde_json::Value;

use crate::bytes::Body;

/// One scripted HTTP reply.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReplySpec {
    /// The status code, 200 by default.
    pub status: Option<u16>,
    /// The reason phrase; the canonical one by default.
    pub reason: Option<String>,
    /// The whole status line, replacing `status` and `reason`, for a
    /// malformed one such as `garbage`.
    pub status_line: Option<String>,
    /// Header lines, verbatim and in order, before the framing header.
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub body: Body,
    #[serde(default)]
    pub framing: Framing,
    /// Points at which the reply stops until its label is released.
    #[serde(default)]
    pub split: Vec<Split>,
    #[serde(default)]
    pub then: Then,
}

/// How the body is framed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Framing {
    /// `Content-Length` with the body's own length.
    #[default]
    ContentLength,
    /// `Content-Length` with this value, whatever the body's length.
    DeclaredLength(usize),
    Chunked(Chunked),
    /// Neither header: the body ends at the close.
    None,
}

/// Chunked framing in detail.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Chunked {
    /// Data chunk sizes, which add up to the body; one chunk by default.
    pub sizes: Option<Vec<usize>>,
    /// Appended to every chunk-size line, such as `;ext=1`.
    #[serde(default)]
    pub extension: String,
    /// Trailer lines after the final chunk.
    #[serde(default)]
    pub trailers: Vec<(String, String)>,
    /// Whether the zero-length final chunk is sent.
    #[serde(default = "yes", rename = "final")]
    pub final_chunk: bool,
}

fn yes() -> bool {
    true
}

impl Default for Chunked {
    fn default() -> Chunked {
        Chunked { sizes: None, extension: String::new(), trailers: Vec::new(), final_chunk: true }
    }
}

impl<'de> Deserialize<'de> for Framing {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Framing, D::Error> {
        let value = Value::deserialize(d)?;
        let bad = || {
            D::Error::custom(format!(
                "framing: expected \"content-length\", {{\"content-length\": N}}, \"chunked\", {{\"chunked\": {{...}}}} or \"none\", got {value}"
            ))
        };
        match &value {
            Value::String(s) => match s.as_str() {
                "content-length" => Ok(Framing::ContentLength),
                "chunked" => Ok(Framing::Chunked(Chunked::default())),
                "none" => Ok(Framing::None),
                _ => Err(bad()),
            },
            Value::Object(map) if map.len() == 1 => {
                let (key, inner) = map.iter().next().unwrap();
                match key.as_str() {
                    "content-length" => inner.as_u64().map(|n| Framing::DeclaredLength(n as usize)).ok_or_else(bad),
                    "chunked" => serde_json::from_value(inner.clone())
                        .map(Framing::Chunked)
                        .map_err(|e| D::Error::custom(format!("framing.chunked: {e}"))),
                    _ => Err(bad()),
                }
            }
            _ => Err(bad()),
        }
    }
}

/// A point in the reply where it stops until `label` is released.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Split {
    /// The byte offset in the whole reply.
    pub at: usize,
    #[serde(rename = "await")]
    pub label: String,
}

/// What happens to the connection once the reply has been written.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Then {
    #[default]
    Close,
    KeepOpen,
    /// Close the connection without writing anything.
    CloseWithoutReply,
}

/// A reply ready to write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Encoded {
    pub bytes: Vec<u8>,
    /// Absolute offsets into `bytes`, increasing, with their labels.
    pub splits: Vec<(usize, String)>,
    pub then: Then,
}

/// The canonical reason phrase for `status`, or "" for one not listed.
pub fn canonical_reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        412 => "Precondition Failed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "",
    }
}

impl ReplySpec {
    /// The status line.
    pub fn status_line(&self) -> String {
        if let Some(line) = &self.status_line {
            return line.clone();
        }
        let status = self.status.unwrap_or(200);
        let reason = self.reason.clone().unwrap_or_else(|| canonical_reason(status).to_string());
        if reason.is_empty() {
            format!("HTTP/1.1 {status}")
        } else {
            format!("HTTP/1.1 {status} {reason}")
        }
    }

    /// The reply's bytes and split points. For a `stream`, the final chunk
    /// is left out so that watch lines can follow.
    pub fn encode(&self, stream: bool) -> Result<Encoded, String> {
        if self.then == Then::CloseWithoutReply {
            if !self.split.is_empty() {
                return Err("split: a reply closed without a reply has no bytes to split".into());
            }
            return Ok(Encoded { bytes: Vec::new(), splits: Vec::new(), then: self.then });
        }
        let body = &self.body.0;
        let mut head = format!("{}\r\n", self.status_line());
        for (name, value) in &self.headers {
            head += &format!("{name}: {value}\r\n");
        }
        match &self.framing {
            Framing::ContentLength => head += &format!("Content-Length: {}\r\n", body.len()),
            Framing::DeclaredLength(n) => head += &format!("Content-Length: {n}\r\n"),
            Framing::Chunked(_) => head += "Transfer-Encoding: chunked\r\n",
            Framing::None => {}
        }
        head += "\r\n";
        let mut bytes = head.into_bytes();
        match &self.framing {
            Framing::Chunked(c) => bytes.extend(chunk(body, c, stream)?),
            _ => bytes.extend_from_slice(body),
        }
        let mut splits = Vec::new();
        let mut last = 0;
        for s in &self.split {
            if s.at <= last || s.at >= bytes.len() {
                return Err(format!(
                    "split: offset {} must be greater than {last} and less than the reply's {} bytes",
                    s.at,
                    bytes.len()
                ));
            }
            last = s.at;
            splits.push((s.at, s.label.clone()));
        }
        Ok(Encoded { bytes, splits, then: self.then })
    }
}

/// `body` in chunks, with the final chunk unless `stream` or turned off.
fn chunk(body: &[u8], c: &Chunked, stream: bool) -> Result<Vec<u8>, String> {
    let sizes = match &c.sizes {
        Some(sizes) => sizes.clone(),
        None if body.is_empty() => Vec::new(),
        None => vec![body.len()],
    };
    if sizes.iter().sum::<usize>() != body.len() || sizes.contains(&0) {
        return Err(format!(
            "framing.chunked.sizes: {sizes:?} must be non-zero and add up to the body's {} bytes",
            body.len()
        ));
    }
    let mut out = Vec::new();
    let mut at = 0;
    for size in sizes {
        out.extend(format!("{size:x}{}\r\n", c.extension).into_bytes());
        out.extend_from_slice(&body[at..at + size]);
        out.extend_from_slice(b"\r\n");
        at += size;
    }
    if c.final_chunk && !stream {
        out.extend(format!("0{}\r\n", c.extension).into_bytes());
        for (name, value) in &c.trailers {
            out.extend(format!("{name}: {value}\r\n").into_bytes());
        }
        out.extend_from_slice(b"\r\n");
    }
    Ok(out)
}

/// One watch line as a chunk: the line and its newline, framed.
pub fn watch_chunk(line: &[u8]) -> Vec<u8> {
    let mut out = format!("{:x}\r\n", line.len() + 1).into_bytes();
    out.extend_from_slice(line);
    out.extend_from_slice(b"\n\r\n");
    out
}
