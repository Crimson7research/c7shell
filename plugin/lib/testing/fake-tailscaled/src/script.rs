//! A script of LocalAPI replies: ordered rules, each matching a method and a
//! target or path, and answering with a reply, a hold or a watch stream.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use crate::reply::{Chunked, Encoded, Framing, ReplySpec};
use crate::request::Request;
use crate::server::MAX_WRITE;

/// What a rule matches.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Match {
    pub method: String,
    /// The exact request target, query included.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// The target without its query.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

impl Match {
    pub fn matches(&self, r: &Request) -> bool {
        r.method() == self.method
            && self.target.as_ref().is_none_or(|t| r.target() == *t)
            && self.path.as_ref().is_none_or(|p| r.path() == *p)
    }

    pub fn validate(&self) -> Result<(), String> {
        match (&self.target, &self.path) {
            (Some(_), None) | (None, Some(_)) => Ok(()),
            _ => Err("match: give exactly one of target and path".into()),
        }
    }
}

/// How many requests a rule answers before the next rule is tried.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Times {
    N(usize),
    #[default]
    Always,
}

impl<'de> Deserialize<'de> for Times {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Times, D::Error> {
        match Value::deserialize(d)? {
            Value::String(s) if s == "always" => Ok(Times::Always),
            Value::Number(n) if n.as_u64().is_some_and(|n| n > 0) => Ok(Times::N(n.as_u64().unwrap() as usize)),
            other => Err(D::Error::custom(format!("times: expected a positive count or \"always\", got {other}"))),
        }
    }
}

/// One rule, as written in a scenario's `fake.rules`.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    #[serde(rename = "match")]
    pub matcher: Match,
    #[serde(default)]
    pub times: Times,
    pub reply: Option<ReplySpec>,
    pub hold: Option<bool>,
    pub stream: Option<ReplySpec>,
}

/// What a rule does with a request it matches.
#[derive(Clone, Debug)]
pub(crate) enum Action {
    Reply(Encoded),
    Hold,
    Stream(Encoded),
}

/// Fails when `len` bytes would not fit one write the fake may make.
pub(crate) fn within_write_limit(what: &str, len: usize) -> Result<(), String> {
    if len > MAX_WRITE {
        return Err(format!("{what} is {len} bytes, over the fake's {MAX_WRITE}-byte write limit"));
    }
    Ok(())
}

impl Rule {
    fn action(&self) -> Result<Action, String> {
        match (&self.reply, self.hold, &self.stream) {
            (Some(reply), None, None) => {
                let encoded = reply.encode(false)?;
                within_write_limit("the reply", encoded.bytes.len())?;
                Ok(Action::Reply(encoded))
            }
            (None, Some(true), None) => Ok(Action::Hold),
            (None, None, Some(stream)) => {
                // push_watch_line writes each line as one plain chunk.
                if stream.framing != Framing::Chunked(Chunked::default()) {
                    return Err(format!(
                        "stream: framing must be \"chunked\", with no sizes, extension, trailers or final, since watch lines are written as plain chunks; got {:?}",
                        stream.framing
                    ));
                }
                let encoded = stream.encode(true)?;
                if !encoded.splits.is_empty() {
                    return Err("stream: a stream head cannot be split".into());
                }
                within_write_limit("the stream head", encoded.bytes.len())?;
                Ok(Action::Stream(encoded))
            }
            _ => Err("a rule needs exactly one of reply, \"hold\": true and stream".into()),
        }
    }
}

/// The ordered rules a fake answers from.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Script {
    pub rules: Vec<Rule>,
}

impl Script {
    /// Checks every rule and encodes every reply.
    pub fn validate(&self) -> Result<(), String> {
        self.compile().map(|_| ())
    }

    pub(crate) fn compile(&self) -> Result<Compiled, String> {
        let rules = self
            .rules
            .iter()
            .enumerate()
            .map(|(i, rule)| {
                rule.matcher.validate().map_err(|e| format!("rules[{i}].{e}"))?;
                let action = rule.action().map_err(|e| format!("rules[{i}]: {e}"))?;
                Ok(CompiledRule { matcher: rule.matcher.clone(), times: rule.times, used: 0, action })
            })
            .collect::<Result<_, String>>()?;
        Ok(Compiled { rules })
    }
}

pub(crate) struct CompiledRule {
    matcher: Match,
    times: Times,
    used: usize,
    action: Action,
}

/// A script ready to answer from, counting each rule's uses.
pub(crate) struct Compiled {
    rules: Vec<CompiledRule>,
}

impl Compiled {
    /// The action of the first rule that matches `r` and is not used up.
    pub(crate) fn answer(&mut self, r: &Request) -> Option<Action> {
        let rule = self
            .rules
            .iter_mut()
            .find(|rule| rule.matcher.matches(r) && !matches!(rule.times, Times::N(n) if rule.used >= n))?;
        rule.used += 1;
        Some(rule.action.clone())
    }
}
