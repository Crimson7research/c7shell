//! The exit-node list: R-QML-11, R-QML-17, R-QML-18 and R-QML-19
//! (`tests/tailscale-qml-test.qml:736-822` and `:1077-1222` at a38dbca).

use serde_json::{json, Value};

use crate::views::ui::exit_nodes;
use crate::views::{El, Views};

/// Connected and writable, the three exit nodes seeded, no exit node
/// selected, the panel open and the exit sub-card folded out.
fn exit_open(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.stage(&[
        ("writable", json!(true)),
        ("writeError", json!("")),
        ("exitNodeId", json!("")),
        ("recommendedExitNodeId", json!("nCCC1CNTRL")),
    ])?;
    v.seed("Tailscale.exitNodes", &exit_nodes())?;
    v.open_panel()?;
    v.set("pop", "expanded", json!("exit"))
}

/// The visible `ts-exit-row`s whose check glyph shows, by node id.
fn checked_rows(v: &Views) -> Result<Vec<Value>, String> {
    let mut ids = Vec::new();
    for o in v.panel_shown("ts-exit-row")? {
        if v.glyph_shown(o)? {
            ids.push(v.get(o, "nodeId")?);
        }
    }
    Ok(ids)
}

/// Whether `o`'s title is drawn in `Theme.textDisabled`.
fn dimmed(v: &Views, o: El) -> Result<bool, String> {
    Ok(v.get(o, "titleColor")? == v.theme("textDisabled")?)
}

/// R-QML-11: `none`, the recommended row and the check mark.
pub fn qml_11_exit_list(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.open_panel()?;
    let two = json!([exit_nodes()[0], exit_nodes()[1]]);
    v.seed("Tailscale.exitNodes", &two)?;
    v.set("Tailscale", "recommendedExitNodeId", json!("nCCC1CNTRL"))?;
    v.invoke(v.panel_one("ts-exit-row-entry")?, "clicked", json!([]))?;
    let none = v.panel_one("ts-exit-none")?;
    let checked = v.flag(none, "visible")? && v.flag(none, "active")? && v.glyph_shown(none)?;
    v.check("none-checked", checked, json!({ "active": v.get(none, "active")?, "glyph": v.glyph_shown(none)? }));
    v.check("none-live", !dimmed(v, none)?, v.get(none, "titleColor")?);
    let recommended = v.panel_shown("ts-exit-recommended")?;
    let titles = v.each(&recommended, "title")?;
    v.check("one-recommended", titles == json!(["pentest-exit-node"]), titles);
    let rows = v.panel_shown("ts-exit-row")?;
    let titles = v.each(&rows, "title")?;
    v.check("two-rows-by-label", titles == json!(["host-5", "pentest-exit-node"]), titles);
    v.invoke("Tailscale.exitNodes", "append", json!([exit_nodes()[2]]))?;
    v.stage(&[
        ("exitNodeActive", json!(true)),
        ("exitNodeOnline", json!(true)),
        ("exitNodeName", json!("pentest-exit-node")),
        ("exitNodeId", json!("nCCC1CNTRL")),
    ])?;
    let ids = checked_rows(v)?;
    v.check("checks-by-id", ids == [json!("nCCC1CNTRL")], json!(ids));
    v.stage(&[("exitNodeActive", json!(false)), ("exitNodeId", json!("")), ("exitNodeName", json!(""))])?;
    let ids = checked_rows(v)?;
    v.check("none-checked-after", ids.is_empty(), json!(ids));
    v.invoke("Tailscale.exitNodes", "remove", json!([2]))?;
    v.set("Tailscale", "recommendedExitNodeId", json!("nZZZ1CNTRL"))?;
    let stale = (v.panel_shown("ts-exit-recommended")?.len(), v.panel_shown("ts-exit-recommended-label")?.len());
    v.check("unknown-suggestion", stale == (0, 0), json!(stale));
    v.set("Tailscale", "recommendedExitNodeId", json!("nCCC1CNTRL"))?;
    let labels = v.panel_shown("ts-exit-recommended-label")?.len();
    v.check("heading-back", labels == 1, json!(labels));
    Ok(())
}

/// R-QML-17: exit rows request by node ID, live while writable.
pub fn qml_17_rows_request_by_id(v: &mut Views) -> Result<(), String> {
    exit_open(v)?;
    let rows = v.panel_shown("ts-exit-row")?;
    v.check("three-rows", rows.len() == 3, json!(rows.len()));
    let mut live = true;
    for o in &rows {
        live &= !dimmed(v, *o)? && v.flag(*o, "hoverable")?;
    }
    v.check("rows-live", live, v.each(&rows, "titleColor")?);
    let none = v.panel_one("ts-exit-none")?;
    v.check("none-live", !dimmed(v, none)?, v.get(none, "titleColor")?);
    v.take_calls()?;
    let mut twin = None;
    for o in &rows {
        if v.get(*o, "nodeId")? == json!("nFFF1CNTRL") {
            twin = Some(*o);
        }
    }
    let twin = twin.ok_or("precondition: a row for the twin nFFF1CNTRL")?;
    v.invoke(twin, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("twin-by-id", calls == "setExitNode(nFFF1CNTRL)", json!(calls));
    let ids = checked_rows(v)?;
    v.check("unchecked-until-reported", ids.is_empty(), json!(ids));
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(true)), ("exitNodeId", json!("nFFF1CNTRL"))])?;
    let ids = checked_rows(v)?;
    v.check("checked-once-reported", ids == [json!("nFFF1CNTRL")], json!(ids));
    v.stage(&[("exitNodeActive", json!(false)), ("exitNodeId", json!(""))])?;
    v.invoke(v.panel_one("ts-exit-none")?, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("none-sends-empty", calls == "setExitNode()", json!(calls));
    let suggested = v.panel_shown("ts-exit-recommended")?;
    v.check("one-recommended", suggested.len() == 1, json!(suggested.len()));
    if let Some(row) = suggested.first().copied() {
        v.invoke(row, "clicked", json!([]))?;
        let calls = v.calls()?;
        v.check("recommended-sends", calls == "setExitNode(nCCC1CNTRL)", json!(calls));
    }
    Ok(())
}

/// R-QML-18: the LAN-access switch reads the pref back, and asks for the
/// opposite of it.
pub fn qml_18_lan_switch(v: &mut Views) -> Result<(), String> {
    exit_open(v)?;
    v.set("Tailscale", "exitNodeAllowLANAccess", json!(true))?;
    let lan = v.panel_one("ts-exit-lan")?;
    let switch = v.panel_one("ts-exit-lan-switch")?;
    v.check("reads-true", v.flag(switch, "checked")?, v.get(switch, "checked")?);
    v.take_calls()?;
    v.invoke(lan, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("asks-false", calls == "setExitNodeAllowLANAccess(false)", json!(calls));
    v.check("waits-for-the-daemon", v.flag(switch, "checked")?, v.get(switch, "checked")?);
    v.set("Tailscale", "exitNodeAllowLANAccess", json!(false))?;
    v.check("follows-false", !v.flag(switch, "checked")?, v.get(switch, "checked")?);
    v.invoke(lan, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("asks-true", calls == "setExitNodeAllowLANAccess(true)", json!(calls));
    v.check("unapplied-unmoved", !v.flag(switch, "checked")?, v.get(switch, "checked")?);
    Ok(())
}

/// The visible exit rows' titles.
fn row_titles(v: &Views) -> Result<Value, String> {
    let rows = v.panel_shown("ts-exit-row")?;
    v.each(&rows, "title")
}

/// R-QML-19: exit-node search.
pub fn qml_19_exit_search(v: &mut Views) -> Result<(), String> {
    exit_open(v)?;
    let search = v.panel_one("ts-exit-search-input")?;
    v.set(search, "text", json!("HOST"))?;
    v.check("host-one-row", row_titles(v)? == json!(["host-5"]), row_titles(v)?);
    let recommended = v.panel_shown("ts-exit-recommended")?.len();
    v.check("host-no-recommended", recommended == 0, json!(recommended));
    let no_match = v.panel_shown("ts-exit-no-match")?.len();
    v.check("host-matched", no_match == 0, json!(no_match));
    let none = v.get(v.panel_one("ts-exit-none")?, "visible")?;
    v.check("host-none-stays", none == json!(true), none);
    v.set(search, "text", json!("no-node-answers-to-this"))?;
    v.check("nothing-no-rows", row_titles(v)? == json!([]), row_titles(v)?);
    let no_match = v.panel_shown("ts-exit-no-match")?;
    let titles = v.each(&no_match, "title")?;
    v.check("nothing-no-matches", titles == json!(["no matches"]), titles);
    let empty = v.panel_shown("ts-exit-empty")?.len();
    v.check("nothing-not-empty", empty == 0, json!(empty));
    v.set(search, "text", json!(""))?;
    let rows = v.panel_shown("ts-exit-row")?.len();
    v.check("cleared-three", rows == 3, json!(rows));
    let no_match = v.panel_shown("ts-exit-no-match")?.len();
    v.check("cleared-no-no-match", no_match == 0, json!(no_match));
    v.seed("Tailscale.exitNodes", &json!([]))?;
    let shown = (v.panel_shown("ts-exit-empty")?.len(), v.panel_shown("ts-exit-no-match")?.len());
    v.check("empty-only", shown == (1, 0), json!(shown));
    v.seed("Tailscale.exitNodes", &exit_nodes())?;
    let rows = v.panel_shown("ts-exit-row")?.len();
    v.check("reseeded-three", rows == 3, json!(rows));
    Ok(())
}
