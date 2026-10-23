//! The file regex a matcher is restricted to, and `clang-query` run over a
//! small unit through its compile database.

mod support;

use mutate_cpp::query::{anchored, find};
use support::{project, Dir, UNIT};

#[test]
fn a_path_becomes_a_regex_matching_exactly_it() {
    assert_eq!(anchored("/a/b.c++/x(1).cpp"), r"^/a/b\.c\+\+/x\(1\)\.cpp$");
}

#[test]
fn it_finds_each_kind_of_site_in_a_unit() {
    let d = Dir::new("query-find");
    let (tree, build) = (d.0.join("tree"), d.0.join("out"));
    project(&tree, &build, &[("a.cpp", UNIT)]);
    let unit = tree.join("a.cpp");
    let (sites, _) = find(&build, &unit, &unit).unwrap();
    let got: Vec<(u32, &str, &str)> = sites.iter().map(|s| (s.line, s.from.as_str(), s.to.as_str())).collect();
    for want in [(3, "==", "!="), (3, "&&", "||"), (3, "1", "0"), (3, "true", "false"), (6, "0", "1")] {
        assert!(got.contains(&want), "no {want:?} in {got:?}");
    }
    assert!(got.iter().any(|&(line, from, _)| line == 4 && from == "g()"), "no dropped call in {got:?}");
}

#[test]
fn a_header_is_read_through_the_unit_that_includes_it() {
    let d = Dir::new("query-header");
    let (tree, build) = (d.0.join("tree"), d.0.join("out"));
    project(&tree, &build, &[("h.h", "inline bool h(int a) { return a < 2; }\n"), ("u.cpp", "#include \"h.h\"\n")]);
    let (sites, _) = find(&build, &tree.join("u.cpp"), &tree.join("h.h")).unwrap();
    let got: Vec<(&str, &str)> = sites.iter().map(|s| (s.from.as_str(), s.to.as_str())).collect();
    assert!(got.contains(&("<", "<=")) && got.contains(&("2", "3")), "{got:?}");
}

#[test]
fn a_unit_or_a_file_that_cannot_be_read_is_an_error() {
    let d = Dir::new("query-error");
    let (tree, build) = (d.0.join("tree"), d.0.join("out"));
    project(&tree, &build, &[("a.cpp", UNIT)]);
    let e = find(&build, &tree.join("absent.cpp"), &tree.join("a.cpp")).unwrap_err();
    assert!(e.contains("clang-query on") && e.contains("absent.cpp"), "{e}");
    let missing = find(&build, &tree.join("a.cpp"), &tree.join("none.cpp")).unwrap_err();
    assert!(missing.contains("none.cpp"), "{missing}");
}
