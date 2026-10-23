//! Reads `clang-query`'s `set output dump` output: one tree per match, each
//! node with its depth, kind, source range and the rest of its line.
//!
//! clang abbreviates a location against the last one it printed in the same
//! tree: `col:N` keeps the file and line, `line:L:N` keeps the file.

/// A source location.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Loc {
    pub file: String,
    pub line: u32,
    pub col: u32,
}

/// A node's range: where its first and its last token begin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Range {
    pub begin: Loc,
    pub end: Loc,
}

/// One node of a dumped tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    pub depth: usize,
    pub kind: String,
    /// None for an invalid location.
    pub range: Option<Range>,
    /// A location inside a macro expansion, whose text is not at its range.
    pub macro_expansion: bool,
    /// What follows the range: the type, the operator, the value.
    pub rest: String,
}

/// One match: its nodes in dump order, the root first.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Match {
    pub nodes: Vec<Node>,
}

/// Every match in `text`.
pub fn parse(text: &str) -> Vec<Match> {
    let mut matches: Vec<Match> = Vec::new();
    let mut last: Option<Loc> = None;
    for line in text.lines() {
        if line.starts_with("Match #") {
            matches.push(Match::default());
            last = None;
            continue;
        }
        let Some(current) = matches.last_mut() else { continue };
        if let Some(node) = node(line, &mut last) {
            current.nodes.push(node);
        }
    }
    matches
}

/// The node on `line`, or None for a line that is not one.
fn node(line: &str, last: &mut Option<Loc>) -> Option<Node> {
    let (depth, body) = strip_tree(line);
    let (kind, after) = body.split_once(' ')?;
    if !kind.chars().next().is_some_and(|c| c.is_ascii_uppercase()) || !after.starts_with("0x") {
        return None;
    }
    let after = after.split_once(' ').map_or("", |(_, r)| r);
    let (inside, rest) = bracketed(after)?;
    let macro_expansion = inside.contains("Spelling=");
    let range = range(inside, last);
    Some(Node { depth, kind: kind.to_string(), range, macro_expansion, rest: rest.trim().to_string() })
}

/// The depth of `line` in the tree, and the line without its prefix.
fn strip_tree(line: &str) -> (usize, &str) {
    let mut depth = 0;
    let mut rest = line;
    while let Some(r) = rest.strip_prefix("| ").or_else(|| rest.strip_prefix("  ")) {
        rest = r;
        depth += 1;
    }
    match rest.strip_prefix("|-").or_else(|| rest.strip_prefix("`-")) {
        Some(r) => (depth + 1, r),
        None => (depth, rest),
    }
}

/// The text inside the leading `<...>` of `s`, nested brackets included,
/// and what follows it.
fn bracketed(s: &str) -> Option<(&str, &str)> {
    let s = s.strip_prefix('<')?;
    let mut depth = 1;
    for (i, c) in s.char_indices() {
        match c {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if depth == 0 {
                    return Some((&s[..i], &s[i + 1..]));
                }
            }
            _ => {}
        }
    }
    None
}

/// `begin[, end]`, each resolved against `last`, which it updates.
fn range(inside: &str, last: &mut Option<Loc>) -> Option<Range> {
    if inside.starts_with('<') {
        return None;
    }
    let mut parts = inside.split(", ");
    let begin = resolve(parts.next()?, last)?;
    let end = match parts.next() {
        Some(p) => resolve(p, last)?,
        None => begin.clone(),
    };
    Some(Range { begin, end })
}

/// One printed location: `col:C`, `line:L:C` or `file:L:C`, with any
/// ` <Spelling=...>` dropped.
fn resolve(printed: &str, last: &mut Option<Loc>) -> Option<Loc> {
    let printed = printed.split(" <").next()?;
    let loc = if let Some(c) = printed.strip_prefix("col:") {
        let prev = last.clone()?;
        Loc { col: c.parse().ok()?, ..prev }
    } else if let Some(lc) = printed.strip_prefix("line:") {
        let (l, c) = lc.split_once(':')?;
        Loc { file: last.clone()?.file, line: l.parse().ok()?, col: c.parse().ok()? }
    } else {
        let (rest, c) = printed.rsplit_once(':')?;
        let (file, l) = rest.rsplit_once(':')?;
        Loc { file: file.to_string(), line: l.parse().ok()?, col: c.parse().ok()? }
    };
    *last = Some(loc.clone());
    Some(loc)
}
