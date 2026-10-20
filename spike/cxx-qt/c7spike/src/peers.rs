//! Pure logic: parse a peer line and diff two peer lists into row operations.
//! No Qt here, so it is unit-tested with plain `cargo test`.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub name: String,
    pub online: bool,
}

/// One row operation, applied in order. Row numbers refer to the list as it
/// is at the moment the operation is applied.
#[derive(Debug, PartialEq, Eq)]
pub enum RowOp {
    Remove(usize),
    Insert(usize, Peer),
    Change(usize, Peer),
}

/// Parses `"a=1,b=0"` into peers sorted by name. Unknown or empty parts are skipped.
pub fn parse(line: &str) -> Vec<Peer> {
    let mut peers: Vec<Peer> = line
        .split(',')
        .filter_map(|part| {
            let (name, online) = part.trim().split_once('=')?;
            if name.is_empty() {
                return None;
            }
            Some(Peer { name: name.to_string(), online: online == "1" })
        })
        .collect();
    peers.sort_by(|a, b| a.name.cmp(&b.name));
    peers.dedup_by(|a, b| a.name == b.name);
    peers
}

/// Diffs two name-sorted lists. Rows that keep their name are never removed
/// and re-inserted, so views keep their delegates and persistent indexes.
pub fn diff(old: &[Peer], new: &[Peer]) -> Vec<RowOp> {
    let mut ops = Vec::new();
    // Removals first, from the end, so earlier row numbers stay valid.
    for (row, peer) in old.iter().enumerate().rev() {
        if !new.iter().any(|p| p.name == peer.name) {
            ops.push(RowOp::Remove(row));
        }
    }
    let mut current: Vec<&Peer> = old.iter().filter(|p| new.iter().any(|n| n.name == p.name)).collect();
    for (row, peer) in new.iter().enumerate() {
        match current.get(row) {
            Some(existing) if existing.name == peer.name => {
                if *existing != peer {
                    ops.push(RowOp::Change(row, peer.clone()));
                }
            }
            _ => {
                ops.push(RowOp::Insert(row, peer.clone()));
                current.insert(row, peer);
            }
        }
    }
    ops
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(name: &str, online: bool) -> Peer {
        Peer { name: name.into(), online }
    }

    #[test]
    fn parse_sorts_and_skips_garbage() {
        assert_eq!(parse("b=1, a=0,,=1,x"), vec![p("a", false), p("b", true)]);
    }

    #[test]
    fn keeping_a_and_adding_b_inserts_only_b() {
        assert_eq!(diff(&[p("a", true)], &[p("a", true), p("b", false)]), vec![RowOp::Insert(1, p("b", false))]);
    }

    #[test]
    fn insert_before_a_survivor() {
        assert_eq!(diff(&[p("b", true)], &[p("a", true), p("b", true)]), vec![RowOp::Insert(0, p("a", true))]);
    }

    #[test]
    fn remove_and_change() {
        assert_eq!(
            diff(&[p("a", true), p("b", true), p("c", true)], &[p("b", false)]),
            vec![RowOp::Remove(2), RowOp::Remove(0), RowOp::Change(0, p("b", false))]
        );
    }

    #[test]
    fn unchanged_list_emits_nothing() {
        assert!(diff(&[p("a", true)], &[p("a", true)]).is_empty());
    }
}
