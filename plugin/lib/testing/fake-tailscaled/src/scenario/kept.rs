//! Kept values: a `keep` step stores a member's value under a label, and a
//! `kept` expect compares kept values with each other or with a member now.

use std::collections::BTreeSet;

use serde::Deserialize;

use super::Step;

/// Stores `member`'s current value under `label`, in the driver, as QML
/// holds it: a string by value, a model by identity.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Keep {
    pub label: String,
    pub member: String,
}

/// Exactly one of `distinct`, the labels whose values differ pairwise, and
/// `same` with `as`, a label whose value is still the member's.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeptCheck {
    pub distinct: Option<Vec<String>>,
    pub same: Option<String>,
    #[serde(rename = "as")]
    pub as_member: Option<String>,
}

impl KeptCheck {
    pub fn validate(&self) -> Result<(), String> {
        match (&self.distinct, &self.same, &self.as_member) {
            (Some(labels), None, None) => {
                if labels.len() < 2 {
                    return Err("distinct names at least two labels".into());
                }
                let mut seen = BTreeSet::new();
                match labels.iter().find(|l| !seen.insert(l.as_str())) {
                    Some(twice) => Err(format!("distinct names `{twice}` twice")),
                    None => Ok(()),
                }
            }
            (None, Some(_), Some(member)) if member.is_empty() => Err("as: empty".into()),
            (None, Some(_), Some(_)) => Ok(()),
            _ => Err("give exactly one of distinct and same with as".into()),
        }
    }

    /// The labels it reads.
    pub fn labels(&self) -> Vec<&str> {
        match (&self.distinct, &self.same) {
            (Some(labels), _) => labels.iter().map(String::as_str).collect(),
            (None, Some(label)) => vec![label.as_str()],
            (None, None) => Vec::new(),
        }
    }
}

/// Each keep label is named once, with a member, and each `kept` expect
/// names only labels an earlier step kept.
pub(super) fn validate_keeps(steps: &[Step]) -> Result<(), String> {
    let mut kept = BTreeSet::new();
    for (i, step) in steps.iter().enumerate() {
        match step {
            Step::Keep(k) if k.label.trim().is_empty() => return Err(format!("steps[{i}].keep: empty label")),
            Step::Keep(k) if k.member.is_empty() => return Err(format!("steps[{i}].keep: empty member")),
            Step::Keep(k) if !kept.insert(k.label.as_str()) => {
                return Err(format!("steps[{i}].keep: `{}` twice", k.label))
            }
            Step::Expect(e) => {
                let labels = e.kept.as_ref().map(KeptCheck::labels).unwrap_or_default();
                if let Some(label) = labels.iter().find(|l| !kept.contains(*l)) {
                    return Err(format!("steps[{i}].expect `{}`: kept: no earlier keep `{label}`", e.id));
                }
            }
            _ => {}
        }
    }
    Ok(())
}
