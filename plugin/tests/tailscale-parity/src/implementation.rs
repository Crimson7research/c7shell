//! The implementation of `C7` a run is against (plan decision P9): a name,
//! the directory holding `C7/qmldir`, and the capabilities it offers.

use std::path::PathBuf;

use fake_tailscaled::scenario::{Capability, IMPLEMENTATIONS};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Implementation {
    pub name: String,
    pub qml_dir: PathBuf,
    pub capabilities: Vec<Capability>,
}

const HOW: &str =
    "build #286's module with plugin/tests/tailscale-parity/build-reference.sh and pass its last line as C7_QML_DIR";

impl Implementation {
    /// From `C7_IMPL` and `C7_QML_DIR`.
    pub fn from_env() -> Result<Implementation, String> {
        let name = std::env::var("C7_IMPL").ok();
        let dir = std::env::var("C7_QML_DIR").ok();
        Implementation::from_vars(name.as_deref(), dir.as_deref())
    }

    pub fn from_vars(name: Option<&str>, qml_dir: Option<&str>) -> Result<Implementation, String> {
        let known: Vec<&str> = IMPLEMENTATIONS.iter().map(|(n, _)| *n).collect();
        let name = name.ok_or_else(|| format!("C7_IMPL is unset; name one of {known:?} ({HOW})"))?;
        let (_, capabilities) = IMPLEMENTATIONS
            .iter()
            .find(|(n, _)| *n == name)
            .ok_or_else(|| format!("C7_IMPL `{name}` is not one of {known:?}"))?;
        let qml_dir = PathBuf::from(qml_dir.ok_or_else(|| format!("C7_QML_DIR is unset; {HOW}"))?);
        if !qml_dir.join("C7/qmldir").is_file() {
            return Err(format!("{} holds no C7/qmldir; {HOW}", qml_dir.display()));
        }
        Ok(Implementation { name: name.to_string(), qml_dir, capabilities: capabilities.to_vec() })
    }
}
