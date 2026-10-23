//! The bar slot: R-QML-01 to R-QML-04 (`tests/tailscale-qml-test.qml:183-343`
//! at a38dbca).

use serde_json::json;

use crate::views::Views;

const NODE: &str = "pentest-exit-node";
const CROSS: &str = "\u{2715}";

/// R-QML-01: no slot and no label on a machine without tailscaled.
pub fn qml_01_no_slot(v: &mut Views) -> Result<(), String> {
    v.stage(&[
        ("state", json!({ "enum": "NoState" })),
        ("readError", json!("")),
        ("exitNodeActive", json!(true)),
        ("exitNodeOnline", json!(true)),
        ("exitNodeName", json!(NODE)),
    ])?;
    let slot = v.slot()?;
    v.check("slot-hidden", !v.flag(slot, "visible")?, v.get(slot, "visible")?);
    v.check("no-label", !v.visible_text(NODE)?, v.slot_texts()?);
    Ok(())
}

/// R-QML-02's view halves: a dimmed slot and the read error verbatim, and
/// both gone once it clears.
pub fn qml_02_dimmed_slot(v: &mut Views) -> Result<(), String> {
    let error = "/localapi/v0/status answered HTTP/1.1 403 Forbidden";
    v.stage(&[("state", json!({ "enum": "NoState" })), ("readError", json!(error))])?;
    let slot = v.slot()?;
    v.check("slot-shown", v.flag(slot, "visible")?, v.get(slot, "visible")?);
    let tint = v.icon_tint()?;
    v.check("dimmed", tint == v.theme("textDisabled")?, tint);
    let line = v.panel_one("ts-read-error")?;
    v.check("line-shown", v.flag(line, "visible")?, v.get(line, "visible")?);
    v.check("verbatim", v.text(line, "text")? == error, v.get(line, "text")?);
    v.set("Tailscale", "readError", json!(""))?;
    v.check("line-gone", !v.flag(line, "visible")?, v.get(line, "visible")?);
    v.check("slot-gone", !v.flag(slot, "visible")?, v.get(slot, "visible")?);
    Ok(())
}

/// R-QML-03's view half: after Running, NoState keeps the slot, dims it,
/// and keeps the ✕ and the name of a blocked exit node.
pub fn qml_03_blocked_badge_survives(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(false)), ("exitNodeName", json!(NODE))])?;
    let blocked = v.get("Tailscale", "exitNodeBlocked")?;
    v.require(blocked == json!(true), "the stand-in derives exitNodeBlocked")?;
    v.set("Tailscale", "state", json!({ "enum": "NoState" }))?;
    let slot = v.slot()?;
    v.check("slot-shown", v.flag(slot, "visible")?, v.get(slot, "visible")?);
    let tint = v.icon_tint()?;
    v.check("dimmed", tint == v.theme("textDisabled")?, tint);
    let crimson = v.theme("accentSoft")?;
    let mut cross = false;
    for o in v.visible_of_colour(crimson.as_str().unwrap_or(""))? {
        cross |= v.text(o, "text").is_ok_and(|t| t == CROSS);
    }
    v.check("cross", cross, v.slot_texts()?);
    v.check("name", v.visible_text(NODE)?, v.slot_texts()?);
    Ok(())
}
