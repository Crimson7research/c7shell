//! Mutation sites (plan decision M2 and M3): from `clang-query` dumps of one
//! source file, the token each mutant changes and what it becomes.
//!
//! A site is kept only when its text is where the dump puts it; a node from
//! another file, from a macro expansion, or whose token does not read as
//! the dump says is skipped with the reason.

use crate::dump::{self, Loc, Node};

/// What a matcher finds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Kind {
    /// A comparison or a logical operator.
    Binary,
    /// An integer literal.
    Integer,
    /// `true` or `false`.
    Bool,
    /// A call standing as a statement.
    DropCall,
}

impl Kind {
    /// The `clang-query` matcher for this kind in the file `file_regex`.
    pub fn matcher(self, file_regex: &str) -> String {
        let at = format!("isExpansionInFileMatching(\"{file_regex}\")");
        match self {
            Kind::Binary => {
                format!(
                    "binaryOperator({at}, hasAnyOperatorName(\"==\",\"!=\",\"<\",\"<=\",\">\",\">=\",\"&&\",\"||\"))"
                )
            }
            Kind::Integer => format!("integerLiteral({at})"),
            Kind::Bool => format!("cxxBoolLiteral({at})"),
            Kind::DropCall => format!("callExpr({at}, hasParent(compoundStmt()))"),
        }
    }

    fn root(self) -> &'static [&'static str] {
        match self {
            Kind::Binary => &["BinaryOperator"],
            Kind::Integer => &["IntegerLiteral"],
            Kind::Bool => &["CXXBoolLiteralExpr"],
            Kind::DropCall => &["CallExpr", "CXXMemberCallExpr", "CXXOperatorCallExpr"],
        }
    }
}

/// One mutant: replace `from` at byte `offset` of `file` with `to`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Site {
    pub file: String,
    pub line: u32,
    pub col: u32,
    pub offset: usize,
    pub kind: Kind,
    pub from: String,
    pub to: String,
}

/// The operator a comparison or logical operator becomes.
pub fn partner(op: &str) -> Option<&'static str> {
    Some(match op {
        "==" => "!=",
        "!=" => "==",
        "<" => "<=",
        "<=" => "<",
        ">" => ">=",
        ">=" => ">",
        "&&" => "||",
        "||" => "&&",
        _ => return None,
    })
}

/// The sites in `source`, the text of `file`, from each kind's dump, in
/// source order, and why each node it could not use was skipped.
pub fn sites(file: &str, source: &str, dumps: &[(Kind, &str)]) -> (Vec<Site>, Vec<String>) {
    let text = Text::new(source);
    let mut found = Vec::new();
    let mut skipped = Vec::new();
    for (kind, dump) in dumps {
        for m in dump::parse(dump) {
            let Some(root) = m.nodes.first().filter(|n| kind.root().contains(&n.kind.as_str())) else { continue };
            match site(*kind, file, &text, root, &m.nodes) {
                Ok(s) => found.push(s),
                Err(why) => skipped.push(format!("{} {}: {why}", root.kind, root.rest)),
            }
        }
    }
    found.sort_by_key(|s| (s.offset, s.to.clone()));
    found.dedup_by(|a, b| a.offset == b.offset && a.to == b.to);
    (found, skipped)
}

fn site(kind: Kind, file: &str, text: &Text, root: &Node, nodes: &[Node]) -> Result<Site, String> {
    let range = in_file(root, file)?;
    let (offset, from, to) = match kind {
        Kind::Binary => binary(text, root, nodes, file)?,
        Kind::Integer => integer(text, &range.begin, &root.rest)?,
        Kind::Bool => boolean(text, &range.begin)?,
        Kind::DropCall => {
            let begin = text.offset(&range.begin)?;
            let end = text.offset(&range.end)?;
            let end = end + text.token_len(end);
            (begin, text.slice(begin, end)?.to_string(), String::new())
        }
    };
    let (line, col) = text.line_col(offset);
    Ok(Site { file: file.to_string(), line, col, offset, kind, from, to })
}

/// `node`'s range when it lies in `file` and outside any macro.
fn in_file(node: &Node, file: &str) -> Result<dump::Range, String> {
    if node.macro_expansion {
        return Err("in a macro expansion".into());
    }
    let r = node.range.clone().ok_or("no valid range")?;
    if r.begin.file != file || r.end.file != file {
        return Err(format!("not in {file}"));
    }
    Ok(r)
}

/// The operator token between the left operand's last token and the right
/// operand's first.
fn binary(text: &Text, root: &Node, nodes: &[Node], file: &str) -> Result<(usize, String, String), String> {
    let op = root.rest.rsplit('\'').nth(1).ok_or("no operator")?;
    let to = partner(op).ok_or_else(|| format!("no partner for {op}"))?;
    let mut operands = nodes.iter().filter(|n| n.depth == 1);
    let (lhs, rhs) = (operands.next().ok_or("no left operand")?, operands.next().ok_or("no right operand")?);
    let (l, r) = (in_file(lhs, file)?, in_file(rhs, file)?);
    let after_lhs = text.offset(&l.end)?;
    let after_lhs = after_lhs + text.token_len(after_lhs);
    let before_rhs = text.offset(&r.begin)?;
    let between = text.slice(after_lhs, before_rhs)?;
    let at = between.find(op).ok_or_else(|| format!("'{op}' is not between its operands"))?;
    let rest = between[at + op.len()..].trim_start();
    if !rest.is_empty() || !between[..at].trim().is_empty() {
        return Err(format!("'{op}' is not alone between its operands: {between:?}"));
    }
    Ok((after_lhs + at, op.to_string(), to.to_string()))
}

/// An integer literal's token, and the token of its mutant value with the
/// same suffix: 0 becomes 1, 1 becomes 0, n becomes n + 1.
fn integer(text: &Text, at: &Loc, rest: &str) -> Result<(usize, String, String), String> {
    let offset = text.offset(at)?;
    let token = text.slice(offset, offset + text.token_len(offset))?;
    let value: u64 = rest.rsplit(' ').next().and_then(|v| v.parse().ok()).ok_or("no value")?;
    let digits: String = token.chars().take_while(|c| c.is_ascii_digit() || *c == '\'').collect();
    if digits.replace('\'', "").parse::<u64>().ok() != Some(value) {
        return Err(format!("'{token}' does not read as {value}"));
    }
    let suffix = &token[digits.len()..];
    let mutant = match value {
        0 => 1,
        1 => 0,
        n => n + 1,
    };
    Ok((offset, token.to_string(), format!("{mutant}{suffix}")))
}

fn boolean(text: &Text, at: &Loc) -> Result<(usize, String, String), String> {
    let offset = text.offset(at)?;
    let token = text.slice(offset, offset + text.token_len(offset))?;
    let to = match token {
        "true" => "false",
        "false" => "true",
        other => return Err(format!("'{other}' is no bool literal")),
    };
    Ok((offset, token.to_string(), to.to_string()))
}

/// A source text and where its lines start.
struct Text<'a> {
    source: &'a str,
    starts: Vec<usize>,
}

impl<'a> Text<'a> {
    fn new(source: &'a str) -> Text<'a> {
        let starts = std::iter::once(0).chain(source.match_indices('\n').map(|(i, _)| i + 1)).collect();
        Text { source, starts }
    }

    /// The byte offset of a 1-based line and byte column.
    fn offset(&self, loc: &Loc) -> Result<usize, String> {
        let start = self.starts.get(loc.line as usize - 1).ok_or_else(|| format!("no line {}", loc.line))?;
        let offset = start + loc.col as usize - 1;
        if offset > self.source.len() {
            return Err(format!("{}:{} is past the end", loc.line, loc.col));
        }
        Ok(offset)
    }

    fn line_col(&self, offset: usize) -> (u32, u32) {
        let line = self.starts.partition_point(|s| *s <= offset);
        (line as u32, (offset - self.starts[line - 1] + 1) as u32)
    }

    fn slice(&self, from: usize, to: usize) -> Result<&'a str, String> {
        self.source.get(from..to).ok_or_else(|| format!("no text at {from}..{to}"))
    }

    /// The length of the token at `offset`: a word (identifier or number,
    /// digit separators included) or one other character.
    fn token_len(&self, offset: usize) -> usize {
        let rest = &self.source[offset..];
        let word =
            rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '\'').map(char::len_utf8).sum();
        if word > 0 {
            word
        } else {
            rest.chars().next().map_or(0, char::len_utf8)
        }
    }
}
