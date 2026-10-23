//! The file regex a matcher is restricted to.

use mutate_cpp::query::anchored;

#[test]
fn a_path_becomes_a_regex_matching_exactly_it() {
    assert_eq!(anchored("/a/b.c++/x(1).cpp"), r"^/a/b\.c\+\+/x\(1\)\.cpp$");
}
