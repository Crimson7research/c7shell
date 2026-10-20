//! Pure logic for the Contract singleton: parses one snapshot line into the
//! fields it changes. No Qt here, so it is unit-tested with plain `cargo test`.
//!
//! A line is `key=value` pairs separated by `;`. Only the keys present change;
//! the rest keep their last value (like a partial notification on a bus):
//!
//!   state=Running;expiry=1767225600000;issues=a|b;active=1;online=0;peers=a=1,b=0;exits=a=1
//!
//! `expiry=none` clears the key expiry; `issues=` clears the issues.

use crate::peers::{parse as parse_peers, Peer};

/// The QML names of the State enum, in declaration order (index == value).
pub const STATE_NAMES: [&str; 6] = ["NoState", "NeedsMachineAuth", "NeedsLogin", "Stopped", "Starting", "Running"];

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    /// Index into STATE_NAMES.
    pub state: Option<i32>,
    /// `Some(None)` clears the expiry (a key that does not expire).
    pub key_expiry_ms: Option<Option<i64>>,
    pub issues: Option<Vec<String>>,
    pub exit_node_active: Option<bool>,
    pub exit_node_online: Option<bool>,
    pub peers: Option<Vec<Peer>>,
    pub exit_nodes: Option<Vec<Peer>>,
}

/// Parses one snapshot line. Unknown keys and unparsable values are ignored.
pub fn parse(line: &str) -> Snapshot {
    let mut s = Snapshot::default();
    for part in line.split(';') {
        let Some((key, value)) = part.trim().split_once('=') else { continue };
        match key {
            "state" => s.state = STATE_NAMES.iter().position(|n| *n == value).map(|i| i as i32),
            "expiry" if value == "none" => s.key_expiry_ms = Some(None),
            "expiry" => {
                if let Ok(ms) = value.parse() {
                    s.key_expiry_ms = Some(Some(ms));
                }
            }
            "issues" => s.issues = Some(value.split('|').filter(|i| !i.is_empty()).map(str::to_string).collect()),
            "active" => s.exit_node_active = Some(value == "1"),
            "online" => s.exit_node_online = Some(value == "1"),
            "peers" => s.peers = Some(parse_peers(value)),
            "exits" => s.exit_nodes = Some(parse_peers(value)),
            _ => {}
        }
    }
    s
}

/// The derived flag, computed once here so no backend can disagree about it.
pub fn exit_node_blocked(active: bool, online: bool) -> bool {
    active && !online
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_every_key() {
        let s = parse("state=Running;expiry=1767225600000;issues=a|b;active=1;online=0;peers=b=0,a=1;exits=a=1");
        assert_eq!(s.state, Some(5));
        assert_eq!(s.key_expiry_ms, Some(Some(1_767_225_600_000)));
        assert_eq!(s.issues, Some(vec!["a".to_string(), "b".to_string()]));
        assert_eq!(s.exit_node_active, Some(true));
        assert_eq!(s.exit_node_online, Some(false));
        assert_eq!(s.peers.as_ref().map(|p| p.len()), Some(2));
        assert_eq!(s.peers.unwrap()[0].name, "a");
        assert_eq!(s.exit_nodes.map(|p| p.len()), Some(1));
    }

    #[test]
    fn absent_keys_stay_none_and_clears_are_explicit() {
        assert_eq!(parse(""), Snapshot::default());
        let s = parse("expiry=none;issues=");
        assert_eq!(s.key_expiry_ms, Some(None));
        assert_eq!(s.issues, Some(vec![]));
        assert_eq!(s.state, None);
    }

    #[test]
    fn ignores_garbage() {
        let s = parse("state=Bogus;expiry=soon;nokey;zzz=1");
        assert_eq!(s, Snapshot::default());
        assert_eq!(parse("state=NoState").state, Some(0));
    }

    #[test]
    fn blocked_needs_active_and_offline() {
        assert!(exit_node_blocked(true, false));
        assert!(!exit_node_blocked(true, true));
        assert!(!exit_node_blocked(false, false));
        assert!(!exit_node_blocked(false, true));
    }
}
