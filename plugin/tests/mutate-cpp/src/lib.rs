//! A source mutator for #286's Tailscale C++ (#310): finds mutation sites in
//! clang's AST through `clang-query`, applies one mutant at a time to a copy
//! of the reference tree, rebuilds, runs the kill suite and records each
//! mutant's outcome. It writes no C++ of its own. See
//! `docs/superpowers/plans/2026-10-23-phase2-310.md`.

pub mod dump;
pub mod query;
pub mod record;
pub mod run;
pub mod sites;
pub mod targets;
