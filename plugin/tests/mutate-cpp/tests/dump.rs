//! The `clang-query` dump reader: matches, node depths, and locations as
//! clang abbreviates them (a column alone, or a line and column, relative to
//! the last location printed in the same match).

use mutate_cpp::dump::{parse, Loc};

const DUMP: &str = r#"
Match #1:

Binding for "root":
BinaryOperator 0x5641 </ref/a.cpp:21:13, col:66> 'bool' '=='
|-ImplicitCastExpr 0x5642 <col:13, col:40> 'int' <IntegralCast>
| `-CXXMemberCallExpr 0x5643 <col:13, col:40> 'bool'
|   `-CXXDefaultArgExpr 0x5644 <<invalid sloc>> 'Qt::CaseSensitivity'
|     `-DeclRefExpr 0x5645 </usr/include/q.h:432:74, col:78> 'Qt::CaseSensitivity'
`-ParenExpr 0x5646 </ref/a.cpp:21:45, line:22:3> 'bool'

Match #2:

Binding for "root":
IntegerLiteral 0x5650 </ref/a.cpp:46:18> 'int' 0

2 matches.
"#;

fn loc(file: &str, line: u32, col: u32) -> Option<Loc> {
    Some(Loc { file: file.into(), line, col })
}

#[test]
fn it_reads_each_match_and_its_nodes_with_their_depth() {
    let matches = parse(DUMP);
    assert_eq!(matches.len(), 2);
    let kinds: Vec<(&str, usize)> = matches[0].nodes.iter().map(|n| (n.kind.as_str(), n.depth)).collect();
    assert_eq!(
        kinds,
        [
            ("BinaryOperator", 0),
            ("ImplicitCastExpr", 1),
            ("CXXMemberCallExpr", 2),
            ("CXXDefaultArgExpr", 3),
            ("DeclRefExpr", 4),
            ("ParenExpr", 1)
        ]
    );
    assert_eq!(matches[0].nodes[0].rest, "'bool' '=='");
    assert_eq!(matches[1].nodes[0].rest, "'int' 0");
}

#[test]
fn it_resolves_abbreviated_locations_against_the_last_one() {
    let m = &parse(DUMP)[0];
    let r = |i: usize| m.nodes[i].range.clone();
    assert_eq!(
        r(0).map(|r| (r.begin, r.end)),
        Some((loc("/ref/a.cpp", 21, 13).unwrap(), loc("/ref/a.cpp", 21, 66).unwrap()))
    );
    assert_eq!(r(1).map(|r| r.end), loc("/ref/a.cpp", 21, 40));
    assert!(r(3).is_none(), "an invalid location has no range");
    assert_eq!(r(4).map(|r| r.end), loc("/usr/include/q.h", 432, 78));
    assert_eq!(
        r(5).map(|r| (r.begin, r.end)),
        Some((loc("/ref/a.cpp", 21, 45).unwrap(), loc("/ref/a.cpp", 22, 3).unwrap()))
    );
}

#[test]
fn a_single_location_is_its_own_end_and_each_match_starts_afresh() {
    let m = &parse(DUMP)[1];
    let r = m.nodes[0].range.clone().unwrap();
    assert_eq!((r.begin.clone(), r.end), (loc("/ref/a.cpp", 46, 18).unwrap(), r.begin));
}

#[test]
fn a_macro_location_is_marked() {
    let text = "Match #1:\n\nBinding for \"root\":\nCallExpr 0x1 </ref/a.cpp:3:5 <Spelling=/usr/include/q.h:9:1>, col:20> 'void'\n";
    let m = &parse(text)[0];
    assert!(m.nodes[0].macro_expansion);
    let plain = &parse(DUMP)[0];
    assert!(!plain.nodes[0].macro_expansion);
}
