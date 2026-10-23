//! Mutation sites from dumps: each kind's site at its token, with what it
//! becomes, and every node whose text is not where the dump says skipped.

use mutate_cpp::sites::{sites, Kind, Site};

// Test data for the site finder: text in C's syntax, never compiled.
const SOURCE: &str =
    "int f(int a, int b) {\n    if (a < 0 && b) return 1;\n    g();\n    bool t = true;\n    return a == b && t;\n}\n";

const BINARY: &str = r#"
Match #1:
BinaryOperator 0x1 </s.c:2:9, col:18> 'bool' '&&'
|-BinaryOperator 0x2 <col:9, col:13> 'bool' '<'
| |-ImplicitCastExpr 0x3 <col:9> 'int'
| `-IntegerLiteral 0x4 <col:13> 'int' 0
`-ImplicitCastExpr 0x5 <col:18> 'bool'
Match #2:
BinaryOperator 0x2 </s.c:2:9, col:13> 'bool' '<'
|-ImplicitCastExpr 0x3 <col:9> 'int'
`-IntegerLiteral 0x4 <col:13> 'int' 0
Match #3:
BinaryOperator 0x6 </s.c:5:12, col:22> 'bool' '&&'
|-BinaryOperator 0x7 <col:12, col:17> 'bool' '=='
| |-ImplicitCastExpr 0x8 <col:12> 'int'
| `-ImplicitCastExpr 0x9 <col:17> 'int'
`-ImplicitCastExpr 0xa <col:22> 'bool'
Match #4:
BinaryOperator 0x7 </s.c:5:12, col:17> 'bool' '=='
|-ImplicitCastExpr 0x8 <col:12> 'int'
`-ImplicitCastExpr 0x9 <col:17> 'int'
"#;

const INTEGER: &str = r#"
Match #1:
IntegerLiteral 0x4 </s.c:2:13> 'int' 0
Match #2:
IntegerLiteral 0xb </s.c:2:28> 'int' 1
"#;

const BOOL: &str = "Match #1:\nCXXBoolLiteralExpr 0xc </s.c:4:14> 'bool' true\n";

const CALL: &str = "Match #1:\nCallExpr 0xd </s.c:3:5, col:7> 'void'\n`-ImplicitCastExpr 0xe <col:5> 'void (*)()'\n";

fn found() -> (Vec<Site>, Vec<String>) {
    sites(
        "/s.c",
        SOURCE,
        &[(Kind::Binary, BINARY), (Kind::Integer, INTEGER), (Kind::Bool, BOOL), (Kind::DropCall, CALL)],
    )
}

fn brief(s: &Site) -> (u32, u32, &str, &str) {
    (s.line, s.col, s.from.as_str(), s.to.as_str())
}

#[test]
fn it_finds_each_kind_at_its_token_once() {
    let (sites, skipped) = found();
    assert!(skipped.is_empty(), "{skipped:?}");
    let got: Vec<_> = sites.iter().map(brief).collect();
    assert_eq!(
        got,
        [
            (2, 11, "<", "<="),
            (2, 13, "0", "1"),
            (2, 15, "&&", "||"),
            (2, 28, "1", "0"),
            (3, 5, "g()", ""),
            (4, 14, "true", "false"),
            (5, 14, "==", "!="),
            (5, 19, "&&", "||"),
        ]
    );
    for s in &sites {
        assert_eq!(&SOURCE[s.offset..s.offset + s.from.len()], s.from, "{s:?}");
    }
}

#[test]
fn each_operator_becomes_its_partner() {
    use mutate_cpp::sites::partner;
    let pairs =
        [("==", "!="), ("!=", "=="), ("<", "<="), ("<=", "<"), (">", ">="), (">=", ">"), ("&&", "||"), ("||", "&&")];
    for (from, to) in pairs {
        assert_eq!(partner(from), Some(to));
    }
    assert_eq!(partner("+"), None);
}

#[test]
fn an_integer_keeps_its_suffix() {
    let source = "x = 16u;\ny = 2'000;\n";
    let dump = "Match #1:\nIntegerLiteral 0x1 </s.c:1:5> 'unsigned int' 16\nMatch #2:\nIntegerLiteral 0x2 </s.c:2:5> 'int' 2000\n";
    let (sites, skipped) = sites("/s.c", source, &[(Kind::Integer, dump)]);
    assert!(skipped.is_empty(), "{skipped:?}");
    let got: Vec<_> = sites.iter().map(brief).collect();
    assert_eq!(got, [(1, 5, "16u", "17u"), (2, 5, "2'000", "2001")]);
}

#[test]
fn it_skips_a_node_whose_text_is_not_at_its_range_or_in_another_file() {
    let dump = "Match #1:\nBinaryOperator 0x1 </s.c:2:9, col:13> 'bool' '<='\n|-ImplicitCastExpr 0x3 <col:9> 'int'\n`-IntegerLiteral 0x4 <col:13> 'int' 0\n\
                Match #2:\nIntegerLiteral 0x5 </other.h:1:1> 'int' 3\n\
                Match #3:\nCallExpr 0x6 </s.c:3:5 <Spelling=/q.h:1:1>, col:7> 'void'\n";
    let (sites, skipped) =
        sites("/s.c", SOURCE, &[(Kind::Binary, dump), (Kind::Integer, dump), (Kind::DropCall, dump)]);
    assert!(sites.is_empty(), "{sites:?}");
    assert_eq!(skipped.len(), 3, "{skipped:?}");
    assert!(skipped.iter().any(|s| s.contains("'<='")), "{skipped:?}");
    assert!(skipped.iter().any(|s| s.contains("macro")), "{skipped:?}");
}
