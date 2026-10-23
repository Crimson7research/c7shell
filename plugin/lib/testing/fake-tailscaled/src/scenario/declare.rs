//! The rules for what each implementation is declared to do, shared by the
//! scenario format and the view test header.

use std::collections::{BTreeMap, BTreeSet};

use super::{Capability, Declaration, Failing, Implementation, Tag, Verdict};

/// What a file declares: its tag, the capabilities it needs and its
/// declarations by implementation.
pub(crate) struct Declared<'a> {
    pub tag: Tag,
    pub needs: &'a BTreeSet<Capability>,
    pub on: &'a BTreeMap<String, Declaration>,
}

/// Checks the declarations against `implementations`; `failing_id` says
/// whether a declared failing id is one that may fail.
pub(crate) fn validate_declarations(
    d: &Declared<'_>,
    implementations: &[Implementation<'_>],
    failing_id: &dyn Fn(&str) -> Result<(), String>,
) -> Result<(), String> {
    if let Some((name, _)) = implementations.iter().find(|(n, _)| !d.on.contains_key(*n)) {
        return Err(format!("on.{name}: missing"));
    }
    if let Some(name) = d.on.keys().find(|k| !implementations.iter().any(|(n, _)| n == k)) {
        return Err(format!("on.{name}: not an implementation the runner knows"));
    }
    for (name, capabilities) in implementations {
        validate_declaration(d, name, capabilities, &d.on[*name], failing_id).map_err(|e| format!("on.{name}: {e}"))?;
    }
    Ok(())
}

fn validate_declaration(
    declared: &Declared<'_>,
    name: &str,
    capabilities: &[Capability],
    d: &Declaration,
    failing_id: &dyn Fn(&str) -> Result<(), String>,
) -> Result<(), String> {
    let runnable = declared.needs.iter().all(|n| capabilities.contains(n));
    match (d.result, runnable) {
        (Verdict::CannotRun, true) => {
            return Err(format!("cannot-run, but {name} has every capability this scenario needs"))
        }
        (Verdict::Pass | Verdict::Fail, false) => {
            return Err(format!("{:?} declared, but {name} lacks some of {:?}", d.result, declared.needs))
        }
        _ => {}
    }
    match d.result {
        Verdict::Pass if d.failing.is_some() => return Err("failing: only a fail declares failing".into()),
        Verdict::Fail => validate_failing(d.failing.as_deref(), failing_id)?,
        Verdict::CannotRun if d.failing.is_some() => return Err("failing: cannot-run declares none".into()),
        _ => {}
    }
    if d.result != Verdict::Pass && d.reason.as_deref().is_none_or(|r| r.trim().is_empty()) {
        return Err("reason: a fail or cannot-run says why".into());
    }
    match (declared.tag, name, d.result) {
        (Tag::Fix, "cpp-286", Verdict::Pass) => Err("a fix cannot pass on #286; declare fail or cannot-run".into()),
        (Tag::Parity, "cpp-286", Verdict::Fail) => Err("a parity scenario cannot fail on #286".into()),
        (_, "rust", Verdict::Fail) => Err("the rewrite is declared to pass, or cannot-run until it can".into()),
        _ => Ok(()),
    }
}

fn validate_failing(
    failing: Option<&[Failing]>,
    failing_id: &dyn Fn(&str) -> Result<(), String>,
) -> Result<(), String> {
    let failing = failing.filter(|f| !f.is_empty()).ok_or("failing: a fail names the failing expectations")?;
    let mut seen = BTreeSet::new();
    for f in failing {
        failing_id(&f.id)?;
        if !seen.insert(f.id.as_str()) {
            return Err(format!("failing: `{}` named twice", f.id));
        }
    }
    Ok(())
}
