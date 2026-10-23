//! The import tree a view child loads (plan decision V3): #286's view files
//! copied from the views directory, the stand-ins under `qml/standins/`,
//! and the theme stand-in with its `PaletteStore` generated from the views'
//! own `palette.json`.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

/// The view files the tree takes from the views directory, by their path
/// there; each lands under `qs/` at the same path.
pub const VIEW_FILES: &[&str] = &[
    "Modules/Bar/StatusPill.qml",
    "Modules/Bar/QuickSlot.qml",
    "Common/Icon.qml",
    "Common/ListRow.qml",
    "Common/SectionLabel.qml",
    "Common/TogglePill.qml",
    "Common/GlassPanel.qml",
    "Common/SearchField.qml",
    "Modules/Popovers/TailscalePopover.qml",
    "Modules/Popovers/PeerRow.qml",
    "Modules/Popovers/ExitNodeList.qml",
    "Modules/Popovers/TailscaleSettings.qml",
    "Modules/Popovers/CopyMenu.qml",
    "Modules/Popovers/TailscaleWriteNote.qml",
];

/// The placeholder `qml/standins/qs/Theme/Theme.qml` holds for the icons.
const ICONS_DIR: &str = "@ICONS_DIR@";

/// The stand-ins' directory.
pub fn standins() -> PathBuf {
    crate::qml_file("standins")
}

/// Builds the tree under `into` from the views in `views`: the stand-ins,
/// the view files, the theme's icon folder and its `PaletteStore`.
pub fn build(views: &Path, into: &Path) -> Result<(), String> {
    build_from(&standins(), views, into)
}

/// [`build`], with the stand-ins taken from `standins`.
pub fn build_from(standins: &Path, views: &Path, into: &Path) -> Result<(), String> {
    copy_dir(standins, into)?;
    for file in VIEW_FILES {
        let to = into.join("qs").join(file);
        fs::copy(views.join(file), &to).map_err(|e| format!("copy {}: {e}", views.join(file).display()))?;
    }
    let icons = views.join("Assets/icons");
    if !icons.is_dir() {
        return Err(format!("{} is no directory", icons.display()));
    }
    let theme = into.join("qs/Theme/Theme.qml");
    let text = fs::read_to_string(&theme).map_err(|e| format!("{}: {e}", theme.display()))?;
    if !text.contains(ICONS_DIR) {
        return Err(format!("{} holds no {ICONS_DIR} to name the icons", theme.display()));
    }
    let url = format!("file://{}", icons.display());
    fs::write(&theme, text.replace(ICONS_DIR, &url)).map_err(|e| format!("{}: {e}", theme.display()))?;
    let palette = views.join("palette.json");
    let store = palette_store(&fs::read_to_string(&palette).map_err(|e| format!("{}: {e}", palette.display()))?)
        .map_err(|e| format!("{}: {e}", palette.display()))?;
    fs::write(into.join("qs/Theme/PaletteStore.qml"), store).map_err(|e| format!("write the PaletteStore: {e}"))
}

/// A `PaletteStore` singleton holding `palette.json`'s `palette` and
/// `defaults`, without the `_`-prefixed keys it documents itself with.
pub fn palette_store(json: &str) -> Result<String, String> {
    let doc: Value = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let part = |name: &str| -> Result<String, String> {
        let v = doc.get(name).ok_or_else(|| format!("no `{name}`"))?;
        Ok(without_prose(v).to_string())
    };
    Ok(format!(
        "pragma Singleton\nimport QtQuick\n\nQtObject {{\n    readonly property var palette: ({})\n    readonly property var defaults: ({})\n}}\n",
        part("palette")?,
        part("defaults")?
    ))
}

fn without_prose(v: &Value) -> Value {
    match v {
        Value::Object(m) => Value::Object(
            m.iter().filter(|(k, _)| !k.starts_with('_')).map(|(k, v)| (k.clone(), without_prose(v))).collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(without_prose).collect()),
        other => other.clone(),
    }
}

fn copy_dir(from: &Path, to: &Path) -> Result<(), String> {
    fs::create_dir_all(to).map_err(|e| format!("create {}: {e}", to.display()))?;
    for entry in fs::read_dir(from).map_err(|e| format!("{}: {e}", from.display()))? {
        let path = entry.map_err(|e| e.to_string())?.path();
        let dest = to.join(path.file_name().unwrap_or_default());
        if path.is_dir() {
            copy_dir(&path, &dest)?;
        } else {
            fs::copy(&path, &dest).map_err(|e| format!("copy {}: {e}", path.display()))?;
        }
    }
    Ok(())
}
