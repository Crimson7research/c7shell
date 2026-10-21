//! A fake `tailscaled` for the Tailscale backend's tests.
//!
//! It listens on a Unix socket in the test's private directory, records every
//! request byte, answers from scripted replies, pushes watch lines and can
//! hold a request unanswered. It has no Qt in it: a test drives it through
//! this crate's API in-process, or through the `fake-tailscaled` binary's
//! JSON-lines control protocol.
//!
//! Its behaviour is specified by R-FAKE-01 to R-FAKE-07 in
//! `docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md`, and
//! each is tested by the `r_fake_0N_*` tests under `tests/`.

mod bytes;
pub mod control;
mod reply;
mod request;
pub mod scenario;
mod script;
mod server;

pub use bytes::{decode_hex, encode_hex, Body, Bytes};
pub use reply::{canonical_reason, Chunked, Encoded, Framing, ReplySpec, Split, Then};
pub use request::Request;
pub use script::{Match, Rule, Script, Times};
pub use server::{AfterReply, ClientId, ClientReport, Fake, Handler, State, FAILURE_BOUND};
