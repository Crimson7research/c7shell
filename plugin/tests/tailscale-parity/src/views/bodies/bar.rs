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

/// R-QML-04: the label widens the slot up to its cap, elides past it, and
/// a short name restores the width without eliding.
pub fn qml_04_label_capped(v: &mut Views) -> Result<(), String> {
    let house = "yankee-with-a-long-magicdns-name.example-tailnet.ts.net";
    v.connected()?;
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(true)), ("exitNodeName", json!("sierra"))])?;
    let narrow = v.slot_width()?;
    v.set("Tailscale", "exitNodeName", json!(house))?;
    let capped = v.slot_width()?;
    v.check("long-widens", capped > narrow, json!({ "sierra": narrow, "long": capped }));
    let label = v.label()?;
    v.check("long-elides", v.flag(label, "truncated")?, v.get(label, "truncated")?);
    v.set("Tailscale", "exitNodeName", json!(format!("{house}{house}")))?;
    let doubled = v.slot_width()?;
    v.check("doubled-same-width", doubled == capped, json!({ "long": capped, "doubled": doubled }));
    v.set("Tailscale", "exitNodeName", json!("sierra"))?;
    let back = v.slot_width()?;
    v.check("short-restores", back == narrow, json!({ "sierra": narrow, "again": back }));
    let label = v.label()?;
    v.check("short-not-elided", !v.flag(label, "truncated")?, v.get(label, "truncated")?);
    Ok(())
}

/// The visible slot parts drawn in theme colour `token`.
fn shown_in(v: &Views, token: &str) -> Result<Vec<crate::views::El>, String> {
    let colour = v.theme(token)?;
    v.visible_of_colour(colour.as_str().unwrap_or(""))
}

/// Whether a visible ✕ is drawn in `Theme.accentSoft`.
fn cross_shown(v: &Views) -> Result<bool, String> {
    let mut cross = false;
    for o in shown_in(v, "accentSoft")? {
        cross |= v.text(o, "text").is_ok_and(|t| t == CROSS);
    }
    Ok(cross)
}

/// R-UI-15's view half: the six slot readings, each staged on the stand-in.
pub fn ui_15_six_readings(v: &mut Views) -> Result<(), String> {
    let health = json!(["DNS is not working"]);
    let rows = [
        ("Running", json!([]), false, false, ""),
        ("Stopped", json!([]), false, false, ""),
        ("Running", health.clone(), false, false, ""),
        ("Stopped", health.clone(), false, false, ""),
        ("Running", json!([]), true, true, NODE),
        ("Running", health, true, false, NODE),
    ];
    let transparent = json!("#00000000");
    for (i, (state, issues, active, online, name)) in rows.into_iter().enumerate() {
        let n = i + 1;
        v.stage(&[
            ("state", json!({ "enum": state })),
            ("issues", issues),
            ("exitNodeActive", json!(active)),
            ("exitNodeOnline", json!(online)),
            ("exitNodeName", json!(name)),
        ])?;
        let slot = v.slot()?;
        v.check(&format!("{n}-shown"), v.flag(slot, "visible")?, v.get(slot, "visible")?);
        let border = v.get(slot, "slotBorder")?;
        let want_border = if n == 6 { v.theme("accentBorder")? } else { transparent.clone() };
        v.check(&format!("{n}-border"), border == want_border, border);
        reading(v, n)?;
    }
    Ok(())
}

/// The clauses of reading `n` beyond visibility and the border.
fn reading(v: &mut Views, n: usize) -> Result<(), String> {
    let slot = v.slot()?;
    let tint = v.icon_tint()?;
    let colour = v.get(slot, "slotColor")?;
    let warnings = shown_in(v, "warning")?.len();
    match n {
        1 => {
            v.check("1-colour", colour == json!("#00000000"), colour);
            v.check("1-tint", tint == v.theme("text")?, tint);
            let mut label = false;
            for o in v.slot_parts()? {
                label |= v.flag(o, "visible")? && v.text(o, "text").is_ok_and(|t| !t.is_empty());
            }
            v.check("1-no-label", !label, v.slot_texts()?);
        }
        2 => v.check("2-tint", tint == v.theme("textDisabled")?, tint),
        3 => {
            v.check("3-one-warning", warnings == 1, json!(warnings));
            let crimson = shown_in(v, "accentSoft")?.len();
            v.check("3-no-crimson", crimson == 0, json!(crimson));
        }
        4 => {
            v.check("4-tint", tint == v.theme("textDisabled")?, tint);
            v.check("4-one-warning", warnings == 1, json!(warnings));
        }
        5 => {
            v.check("5-colour", colour == v.theme("accentFill")?, colour);
            v.check("5-tint", tint == v.theme("accentSoft")?, tint);
            v.check("5-name", v.visible_text(NODE)?, v.slot_texts()?);
            v.check("5-no-cross", !cross_shown(v)?, v.slot_texts()?);
        }
        _ => {
            v.check("6-cross", cross_shown(v)?, v.slot_texts()?);
            v.check("6-colour", colour == v.theme("accentFill")?, colour);
            v.check("6-name", v.visible_text(NODE)?, v.slot_texts()?);
            v.check("6-no-warning", warnings == 0, json!(warnings));
        }
    }
    Ok(())
}

/// The view half both R-CONN-15 and R-WATCH-13 share with R-QML-02: with
/// `state` `NoState` and `reason` as `readError`, never another state
/// reported, the slot is visible and dimmed and `ts-read-error` equals it.
fn dimmed_for(v: &mut Views, reason: &str, line: bool) -> Result<(), String> {
    v.stage(&[("state", json!({ "enum": "NoState" })), ("readError", json!(reason))])?;
    let slot = v.slot()?;
    v.check("slot-shown", v.flag(slot, "visible")?, v.get(slot, "visible")?);
    let tint = v.icon_tint()?;
    v.check("dimmed", tint == v.theme("textDisabled")?, tint);
    if line {
        let el = v.panel_one("ts-read-error")?;
        let shown = v.flag(el, "visible")? && v.text(el, "text")? == reason;
        v.check("read-error-line", shown, json!({ "visible": v.get(el, "visible")?, "text": v.get(el, "text")? }));
    }
    Ok(())
}

/// R-CONN-15's view half: the clean-end reason dims the slot.
pub fn conn_15_clean_end_dimmed(v: &mut Views) -> Result<(), String> {
    dimmed_for(v, "/localapi/v0/watch-ipn-bus ended before tailscaled sent a status", false)
}

/// R-WATCH-13's QML half: an unknown state's reason dims the slot and is
/// the panel's read-error line.
pub fn watch_13_unknown_state_dimmed(v: &mut Views) -> Result<(), String> {
    dimmed_for(v, "tailscaled reported an unknown BackendState \"Weird\"", true)
}
