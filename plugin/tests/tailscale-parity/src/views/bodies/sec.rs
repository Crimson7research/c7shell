//! R-SEC-03: network strings are drawn literally, never as markup
//! (`tests/tailscale-qml-test.qml:345-370`, `:464-476` and each
//! `everyTextIsPlain` and `textFormat` check at a38dbca).

use serde_json::json;

use crate::views::ui::{exit_nodes, tailnet_peers, REFUSAL};
use crate::views::{El, Views};

const BOLD: &str = "<b>a</b>";
const IMAGE: &str = "<img src=http://x/>";

/// The bar label for `<b>a</b>` is more than twice as wide as for `a`.
fn bar_label(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(true)), ("exitNodeName", json!("a"))])?;
    v.layout()?;
    let bare = v.number(v.label()?, "implicitWidth")?;
    v.set("Tailscale", "exitNodeName", json!(BOLD))?;
    let label = v.label()?;
    let literal = v.number(label, "implicitWidth")?;
    v.check("bar-label-literal", literal > bare * 2.0, json!({ "a": bare, "<b>a</b>": literal }));
    v.check("bar-label-byte-for-byte", v.get(label, "text")? == json!(BOLD), v.get(label, "text")?);
    v.check_plain("bar-label-plain", label)
}

/// Every Text under each of `names`, one panel element each, is plain; a
/// peer row holds at least three.
fn plain_elements(v: &mut Views, names: &[&str]) -> Result<(), String> {
    for name in names {
        let o = v.panel_one(name)?;
        let (count, _) = v.markup_texts(o)?;
        v.require(count > 0, &format!("{name} holds a Text"))?;
        v.check_plain(&format!("plain-{name}"), o)?;
    }
    Ok(())
}

/// The peer row titled `title`: at least three Texts, every one plain.
fn plain_row(v: &mut Views, id: &str, row: El) -> Result<(), String> {
    let (count, _) = v.markup_texts(row)?;
    v.require(count >= 3, "a peer row holds three or more Texts")?;
    v.check_plain(id, row)
}

/// R-SEC-03: a peer named `<b>a</b>` and a health entry `<img
/// src=http://x/>` reach the views byte for byte and are drawn as plain
/// text, and so is every element that draws a network string.
pub fn sec_03_plain_text(v: &mut Views) -> Result<(), String> {
    bar_label(v)?;
    v.connected_with_peers()?;
    v.open_panel()?;
    let mut peers = tailnet_peers();
    peers[0]["displayName"] = json!(BOLD);
    v.seed("Tailscale.peers", &peers)?;
    v.stage(&[
        ("issues", json!([IMAGE])),
        ("exitNodeActive", json!(true)),
        ("exitNodeOnline", json!(false)),
        ("exitNodeName", json!(BOLD)),
    ])?;
    let issue = v.panel_one("ts-issue")?;
    v.check("issue-literal", v.get(issue, "text")? == json!(IMAGE), v.get(issue, "text")?);
    plain_elements(v, &["ts-issue", "ts-blocked-text", "ts-self-name"])?;
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    let bold = v.peer_row(BOLD)?;
    v.check("peer-title-literal", v.get(bold, "title")? == json!(BOLD), v.get(bold, "title")?);
    plain_row(v, "plain-peer-row", bold)?;
    let owned = v.peer_row("workstation")?;
    v.require(v.get(owned, "subtitle")? == json!("Third Example"), "the owner line is where it is looked for")?;
    plain_row(v, "plain-owned-row", owned)?;
    exit_card(v)?;
    settings_card(v)?;
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL))])?;
    plain_elements(v, &["ts-connect-tip"])
}

/// The exit card's strings.
fn exit_card(v: &mut Views) -> Result<(), String> {
    v.stage(&[("exitNodeActive", json!(false)), ("writable", json!(true)), ("writeError", json!(""))])?;
    let mut nodes = exit_nodes();
    nodes[0]["displayName"] = json!(BOLD);
    v.seed("Tailscale.exitNodes", &nodes)?;
    v.set("pop", "expanded", json!("exit"))?;
    let row = v.panel_shown("ts-exit-row")?.first().copied().ok_or("precondition: an exit row")?;
    v.check_plain("plain-exit-row", row)?;
    plain_elements(v, &["ts-exit-lan", "ts-exit-advertise"])?;
    v.set(v.panel_one("ts-exit-search-input")?, "text", json!("no-node-answers-to-this"))?;
    plain_elements(v, &["ts-exit-no-match"])?;
    v.set(v.panel_one("ts-exit-search-input")?, "text", json!(""))?;
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL))])?;
    plain_elements(v, &["ts-exit-write-error"])
}

/// The settings card's strings.
fn settings_card(v: &mut Views) -> Result<(), String> {
    v.stage(&[("writable", json!(true)), ("writeError", json!("")), ("acceptRoutes", json!(false))])?;
    v.set("pop", "expanded", json!("settings"))?;
    plain_elements(v, &["ts-settings-routes", "ts-settings-dns", "ts-settings-routes-why"])?;
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL))])?;
    plain_elements(v, &["ts-settings-write-error"])
}
