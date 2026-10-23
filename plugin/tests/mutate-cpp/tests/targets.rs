//! The sources #310 mutates and the mutants built from their sites.

use mutate_cpp::sites::{Kind, Site};
use mutate_cpp::targets::{mutant, TARGETS};

#[test]
fn the_targets_are_286s_tailscale_sources_and_the_contract_header() {
    let files: Vec<&str> = TARGETS.iter().map(|t| t.file).collect();
    assert_eq!(
        files,
        [
            "plugin/lib/tailscale/LocalApiClient.cpp",
            "plugin/lib/tailscale/StatusParser.cpp",
            "plugin/lib/tailscale/PeerModel.cpp",
            "plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp",
            "plugin/src/contracts/TailscaleBackend.h",
        ]
    );
    let header = TARGETS.last().unwrap();
    assert_eq!(header.unit, "plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp");
    assert!(TARGETS[..4].iter().all(|t| t.unit == t.file), "a source is its own unit");
}

#[test]
fn a_mutant_is_named_by_its_file_relative_to_the_tree_its_place_and_its_edit() {
    let site = Site {
        file: "/ref/tree/plugin/lib/tailscale/StatusParser.cpp".into(),
        line: 46,
        col: 16,
        offset: 1234,
        kind: Kind::Binary,
        from: "<".into(),
        to: "<=".into(),
    };
    let m = mutant(std::path::Path::new("/ref/tree"), &site).unwrap();
    assert_eq!(m.id, "plugin/lib/tailscale/StatusParser.cpp:46:16:<-><=");
    assert_eq!((m.file.as_str(), m.offset, m.kind.as_str()), ("plugin/lib/tailscale/StatusParser.cpp", 1234, "Binary"));
    let dropped = Site { kind: Kind::DropCall, from: "emit a()".into(), to: String::new(), ..site.clone() };
    assert_eq!(
        mutant(std::path::Path::new("/ref/tree"), &dropped).unwrap().id,
        "plugin/lib/tailscale/StatusParser.cpp:46:16:drop emit a()"
    );
    assert!(mutant(std::path::Path::new("/elsewhere"), &site).is_err());
}
