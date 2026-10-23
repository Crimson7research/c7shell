//! What #310 mutates: #286's Tailscale sources and the inline code of the
//! contract header, each with the translation unit it is compiled in, and
//! the mutant each site becomes.

use std::path::Path;

use crate::run::Mutant;
use crate::sites::{Kind, Site};

/// A mutated file and the unit `clang-query` compiles it as, both relative
/// to the tree's root.
#[derive(Clone, Copy, Debug)]
pub struct Target {
    pub file: &'static str,
    pub unit: &'static str,
}

const BACKEND: &str = "plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp";

/// The files mutated, at a38dbca. `FakeTailscaleBackend.h` is a test double
/// and is left alone.
pub const TARGETS: &[Target] = &[
    Target { file: "plugin/lib/tailscale/LocalApiClient.cpp", unit: "plugin/lib/tailscale/LocalApiClient.cpp" },
    Target { file: "plugin/lib/tailscale/StatusParser.cpp", unit: "plugin/lib/tailscale/StatusParser.cpp" },
    Target { file: "plugin/lib/tailscale/PeerModel.cpp", unit: "plugin/lib/tailscale/PeerModel.cpp" },
    Target { file: BACKEND, unit: BACKEND },
    Target { file: "plugin/src/contracts/TailscaleBackend.h", unit: BACKEND },
];

/// The mutant `site` becomes in a tree whose root is `tree`. Its id names
/// the file relative to the tree, the line and column, and the edit.
pub fn mutant(tree: &Path, site: &Site) -> Result<Mutant, String> {
    let file = Path::new(&site.file)
        .strip_prefix(tree)
        .map_err(|_| format!("{} is not under {}", site.file, tree.display()))?
        .to_string_lossy()
        .into_owned();
    let edit = match site.kind {
        Kind::DropCall => format!("drop {}", site.from),
        _ => format!("{}->{}", site.from, site.to),
    };
    Ok(Mutant {
        id: format!("{file}:{}:{}:{edit}", site.line, site.col),
        file,
        line: site.line,
        col: site.col,
        offset: site.offset,
        kind: format!("{:?}", site.kind),
        from: site.from.clone(),
        to: site.to.clone(),
    })
}
