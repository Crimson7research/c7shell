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

mod request;
mod server;

pub use server::{ClientId, Fake, State, FAILURE_BOUND};
