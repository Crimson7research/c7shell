//! The device list: R-QML-09, R-QML-10, R-QML-12 to R-QML-14 and
//! R-GROUP-06's delegate half (`tests/tailscale-qml-test.qml:586-735`,
//! `:842-1048` and `:1662-1765` at a38dbca).

use serde_json::{json, Value};

use crate::views::ui::{many_peers, tailnet_peers};
use crate::views::{El, Views};

const TANGO_IP4: &str = "100.119.215.89";

/// Connected with the four peers, the panel open and the device list
/// folded out.
fn devices_open(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    Ok(())
}

/// The visible `ts-section` headings, top to bottom.
fn headings(v: &mut Views) -> Result<Vec<String>, String> {
    let mut at = Vec::new();
    for o in v.panel_shown("ts-section")? {
        at.push((v.y_in_panel(o)?, v.text(o, "text")?));
    }
    at.sort_by(|a, b| a.0.total_cmp(&b.0));
    Ok(at.into_iter().map(|(_, t)| t).collect())
}

/// R-QML-09: DNS labels in three sections, folded out of "network devices".
pub fn qml_09_device_list(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    let folded = v.panel_shown("ts-peer")?.len();
    v.check("not-on-root-card", folded == 0, json!(folded));
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    let rows = v.panel_shown("ts-peer")?;
    v.check("four-rows", rows.len() == 4, json!(rows.len()));
    let titles = v.each(&rows, "title")?;
    let by_os_name = titles.as_array().is_some_and(|t| t.contains(&json!("localhost")));
    v.check("no-os-hostname", !by_os_name, titles);
    let ws = v.peer_row("workstation")?;
    v.check("titled-by-label", v.get(ws, "title")? == json!("workstation"), v.get(ws, "title")?);
    let order = headings(v)?;
    v.check("sections", order == ["my devices", "tagged devices", "other users"], json!(order));
    v.check("owner-shown", v.get(ws, "subtitle")? == json!("Third Example"), v.get(ws, "subtitle")?);
    let tango = v.peer_row("tango")?;
    v.check("own-has-no-owner", v.get(tango, "subtitle")? == json!(""), v.get(tango, "subtitle")?);
    v.invoke("Tailscale.peers", "remove", json!([3]))?;
    let left = headings(v)?;
    v.check("empty-group-dropped", left == ["my devices", "tagged devices"], json!(left));
    Ok(())
}

/// The clipboard after `act` on `o`, from `start`.
fn copies(v: &mut Views, o: El, act: &str, start: &str) -> Result<Value, String> {
    v.set("Quickshell", "clipboardText", json!(start))?;
    v.invoke(o, act, json!([]))?;
    v.get("Quickshell", "clipboardText")
}

/// The copy menu's entries on `row`, each activated after a fresh
/// right-click: enabled before, the value copied, the menu closed after.
fn copy_entries(v: &mut Views, row: El, wanted: &[(&str, &str)]) -> Result<(), String> {
    for (entry, value) in wanted {
        v.right_click(row)?;
        let menu = v.panel_one("ts-copy-menu")?;
        v.check(&format!("{entry}-menu-shown"), v.flag(menu, "visible")?, v.get(menu, "visible")?);
        v.check(
            &format!("{entry}-menu-head"),
            v.get(menu, "displayName")? == json!("tango"),
            v.get(menu, "displayName")?,
        );
        let e = v.panel_one(entry)?;
        v.check(&format!("{entry}-enabled"), v.flag(e, "entryEnabled")?, v.get(e, "entryEnabled")?);
        let clip = copies(v, e, "activate", "")?;
        v.check(&format!("{entry}-copies"), clip == json!(value), clip);
        let menu = v.panel_one("ts-copy-menu")?;
        v.check(&format!("{entry}-menu-closed"), !v.flag(menu, "visible")?, v.get(menu, "visible")?);
    }
    Ok(())
}

/// R-QML-10: copying through the clipboard, the right-click menu, and no
/// process in the files that copy.
pub fn qml_10_copying(v: &mut Views) -> Result<(), String> {
    devices_open(v)?;
    let tango = v.peer_row("tango")?;
    let clip = copies(v, tango, "clicked", "")?;
    v.check("click-copies-ip4", clip == json!(TANGO_IP4), clip);
    v.check("copied-feedback", v.flag(tango, "copied")?, v.get(tango, "copied")?);
    let right = v.get("Qt", "RightButton")?;
    let mut areas = 0;
    for o in v.find(tango, None)? {
        areas += usize::from(v.get(o, "acceptedButtons").is_ok_and(|b| b == right));
    }
    v.check("one-right-button-area", areas == 1, json!(areas));
    copy_entries(
        v,
        tango,
        &[
            ("ts-copy-ip4", TANGO_IP4),
            ("ts-copy-ip6", "fd7a:115c:a1e0::3016:83db"),
            ("ts-copy-dns", "tango.example-tailnet.ts.net"),
        ],
    )?;
    v.right_click(v.peer_row("workstation")?)?;
    let menu = v.panel_one("ts-copy-menu")?;
    v.check("menu-head-label", v.get(menu, "displayName")? == json!("workstation"), v.get(menu, "displayName")?);
    v.invoke(menu, "close", json!([]))?;
    v.right_click(v.peer_row("yankee")?)?;
    dead_ip6(v)?;
    v.invoke(v.panel_one("ts-copy-menu")?, "close", json!([]))?;
    bravo_copies(v)?;
    no_process(v)
}

/// On `yankee`, with no IPv6, the entry stays, dead and dimmed.
fn dead_ip6(v: &mut Views) -> Result<(), String> {
    let dead = v.panel_one("ts-copy-ip6")?;
    v.check("dead-visible", v.flag(dead, "visible")?, v.get(dead, "visible")?);
    v.check("dead-disabled", !v.flag(dead, "entryEnabled")?, v.get(dead, "entryEnabled")?);
    let mut colour = Value::Null;
    for o in v.find(dead, None)? {
        if let (Ok(Value::String(_)), Ok(c)) = (v.get(o, "text"), v.get(o, "color")) {
            colour = c;
            break;
        }
    }
    v.check("dead-dimmed", colour == v.theme("textDisabled")?, colour);
    let clip = copies(v, dead, "activate", "untouched")?;
    v.check("dead-copies-nothing", clip == json!("untouched"), clip);
    Ok(())
}

/// The three peers of the delegate checks (`:1663-1673`).
fn three() -> Value {
    let row = |name: &str, n: u32, id: &str| {
        json!({ "hostName": name, "displayName": name, "ip4": format!("100.64.0.{n}"),
                "ip6": format!("fd7a:115c:a1e0::{n}"), "dnsName": format!("{name}.example-tailnet.ts.net"),
                "online": true, "group": 0, "ownerName": "owner@example.com", "nodeId": id,
                "exitNodeOption": false })
    };
    json!([row("alpha", 1, "nAAA1CNTRL"), row("bravo", 2, "nBBB1CNTRL"), row("gamma", 3, "nCCC1CNTRL")])
}

/// Clicking the `bravo` delegate copies bravo's address.
fn bravo_copies(v: &mut Views) -> Result<(), String> {
    v.seed("Tailscale.peers", &three())?;
    let list = v.panel_one("ts-peer-list")?;
    let bravo = v.row_of_node_id(list, "nBBB1CNTRL")?.ok_or("precondition: a delegate for bravo")?;
    let clip = copies(v, bravo, "clicked", "")?;
    v.check("bravo-copies", clip == json!("100.64.0.2"), clip);
    Ok(())
}

/// The files that copy start no process.
fn no_process(v: &mut Views) -> Result<(), String> {
    for file in ["Modules/Popovers/PeerRow.qml", "Modules/Popovers/CopyMenu.qml"] {
        let path = v.views.join(file);
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let spawns = text.contains("Process {") || text.contains("execDetached(");
        v.check(&format!("no-process-{file}"), !spawns, json!(spawns));
    }
    Ok(())
}

/// The chevron's rotation and the panel's height.
fn fold_state(v: &Views, chevron: El) -> Result<(f64, f64), String> {
    Ok((v.number(chevron, "rotation")?, v.number("pop.panel", "height")?))
}

/// Whether `name`'s input has the focus and is the window's focus item,
/// as `holds`, with what each reads.
fn focused(v: &Views, name: &str) -> Result<Value, String> {
    let input = v.panel_one(name)?;
    let (active, window) = (v.flag(input, "activeFocus")?, v.focus()?);
    let holds = active && window == Some(input);
    Ok(json!({ "holds": holds, "activeFocus": active, "window": window.map(|e| e.0), "input": input.0 }))
}

/// R-QML-12: one sub-card at a time folds out between its row and the
/// next, and folding keeps the rows.
pub fn qml_12_sub_cards(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    v.check("opens-by-name", v.flag("pop", "open")?, v.get("pop", "open")?);
    let back = v.panel_all("ts-back")?.len();
    v.check("no-back", back == 0, json!(back));
    let chevron = v.panel_one("ts-devices-chevron")?;
    let (shut_turn, shut) = fold_state(v, chevron)?;
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    let root_rows = ["ts-self-name", "ts-self-ip4", "ts-devices-row", "ts-exit-row-entry"];
    let mut kept = true;
    for name in root_rows {
        kept &= v.flag(v.panel_one(name)?, "visible")?;
    }
    v.check("root-rows-stay", kept, json!(kept));
    let rows = v.panel_shown("ts-peer")?.len();
    v.check("four-rows", rows == 4, json!(rows));
    let (turn, height) = fold_state(v, chevron)?;
    v.check("grows", height > shut, json!({ "shut": shut, "open": height }));
    v.check("chevron-turns", turn != shut_turn, json!(turn));
    let focus = focused(v, "ts-peer-search-input")?;
    v.check("search-focused", focus["holds"] == json!(true), focus);
    let card = v.y_in_panel(v.panel_one("ts-devices-card")?)?;
    let row = v.y_in_panel(v.panel_one("ts-devices-row")?)?;
    let next = v.y_in_panel(v.panel_one("ts-exit-row-entry")?)?;
    v.check("card-between", card > row && card < next, json!({ "row": row, "card": card, "next": next }));
    let tango = v.peer_row("tango")?;
    v.invoke(tango, "clicked", json!([]))?;
    v.require(v.flag(tango, "copied")?, "tango took the copied state")?;
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    let rows = v.panel_shown("ts-peer")?.len();
    v.check("folds-shut", rows == 0, json!(rows));
    let (turn, height) = fold_state(v, chevron)?;
    v.check("chevron-back", turn == shut_turn, json!(turn));
    v.check("height-back", (height - shut).abs() < 1.0, json!({ "shut": shut, "again": height }));
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    let again = v.peer_row("tango")?;
    v.check("same-delegate", again == tango, json!({ "before": tango.0, "after": again.0 }));
    v.check("state-kept", v.flag(again, "copied")?, v.get(again, "copied")?);
    exit_folds_devices(v)?;
    settings_card(v)
}

/// Opening exit from an open device list folds devices away.
fn exit_folds_devices(v: &mut Views) -> Result<(), String> {
    v.invoke(v.panel_one("ts-exit-row-entry")?, "clicked", json!([]))?;
    let root_row = v.get(v.panel_one("ts-self-name")?, "visible")?;
    v.check("exit-keeps-root", root_row == json!(true), root_row);
    let rows = v.panel_shown("ts-peer")?.len();
    v.check("exit-folds-devices", rows == 0, json!(rows));
    let focus = focused(v, "ts-exit-search-input")?;
    v.check("exit-search-focused", focus["holds"] == json!(true), focus);
    Ok(())
}

/// The settings sub-card, from every card shut.
fn settings_card(v: &mut Views) -> Result<(), String> {
    v.set("pop", "expanded", json!(""))?;
    let on_root = v.panel_shown("ts-settings-routes")?.len();
    v.check("settings-not-on-root", on_root == 0, json!(on_root));
    let chevron = v.panel_one("ts-settings-chevron")?;
    let (shut_turn, shut) = fold_state(v, chevron)?;
    let row = v.panel_one("ts-settings-row")?;
    v.invoke(row, "clicked", json!([]))?;
    let root_row = v.get(v.panel_one("ts-self-name")?, "visible")?;
    v.check("settings-keeps-root", root_row == json!(true), root_row);
    let peers = v.panel_shown("ts-peer")?.len();
    v.check("settings-no-peer", peers == 0, json!(peers));
    let (turn, height) = fold_state(v, chevron)?;
    v.check("settings-grows", height > shut, json!({ "shut": shut, "open": height }));
    v.check("settings-chevron-turns", turn != shut_turn, json!(turn));
    let card = v.y_in_panel(v.panel_one("ts-settings-card")?)?;
    let row_y = v.y_in_panel(row)?;
    v.check("settings-card-below", card > row_y, json!({ "row": row_y, "card": card }));
    v.invoke(row, "clicked", json!([]))?;
    let left = v.panel_shown("ts-settings-routes")?.len();
    v.check("settings-folds-shut", left == 0, json!(left));
    let (turn, height) = fold_state(v, chevron)?;
    v.check("settings-chevron-back", turn == shut_turn, json!(turn));
    v.check("settings-height-back", (height - shut).abs() < 1.0, json!({ "shut": shut, "again": height }));
    Ok(())
}

/// The headings and the titles of the visible rows.
fn titles_and_headings(v: &mut Views) -> Result<(Value, Vec<String>), String> {
    let rows = v.panel_shown("ts-peer")?;
    Ok((v.each(&rows, "title")?, headings(v)?))
}

/// R-QML-13: device search tells "no match" from "empty".
pub fn qml_13_device_search(v: &mut Views) -> Result<(), String> {
    devices_open(v)?;
    let count = v.panel_one("ts-devices-count")?;
    v.check("count-4", v.get(count, "text")? == json!("4"), v.get(count, "text")?);
    let search = v.panel_one("ts-peer-search-input")?;
    v.set(search, "text", json!("TANGO"))?;
    let (titles, heads) = titles_and_headings(v)?;
    v.check("tango-one-row", titles == json!(["tango"]), titles);
    v.check("tango-count", v.get(count, "text")? == json!("1"), v.get(count, "text")?);
    v.check("tango-mine-only", heads == ["my devices"], json!(heads));
    let no_match = v.panel_shown("ts-peer-no-match")?.len();
    v.check("tango-matched", no_match == 0, json!(no_match));
    v.set(search, "text", json!("workstation"))?;
    let heads = headings(v)?;
    v.check("workstation-others-only", heads == ["other users"], json!(heads));
    v.set(search, "text", json!("no-device-answers-to-this"))?;
    let (titles, heads) = titles_and_headings(v)?;
    v.check("nothing-no-rows", titles == json!([]), titles);
    v.check("nothing-no-headings", heads.is_empty(), json!(heads));
    let no_match = v.panel_shown("ts-peer-no-match")?.len();
    v.check("nothing-says-no-match", no_match == 1, json!(no_match));
    let empty = v.panel_shown("ts-peer-empty")?.len();
    v.check("nothing-not-empty", empty == 0, json!(empty));
    v.set(search, "text", json!(""))?;
    v.seed("Tailscale.peers", &json!([]))?;
    let no_match = v.panel_shown("ts-peer-no-match")?.len();
    v.check("empty-not-no-match", no_match == 0, json!(no_match));
    v.seed("Tailscale.peers", &tailnet_peers())?;
    let rows = v.panel_shown("ts-peer")?.len();
    v.check("back-to-4", rows == 4, json!(rows));
    v.check("count-4-again", v.get(count, "text")? == json!("4"), v.get(count, "text")?);
    v.seed("Tailscale.peers", &many_peers(50))?;
    v.set(search, "text", json!("node-49"))?;
    let (titles, heads) = titles_and_headings(v)?;
    v.check("far-one-row", titles == json!(["node-49"]), titles);
    v.check("far-others-only", heads == ["other users"], json!(heads));
    Ok(())
}

/// R-QML-14: both lists cap, clip and scroll, and the exit search stays
/// above the scrolling area.
pub fn qml_14_long_lists(v: &mut Views) -> Result<(), String> {
    devices_open(v)?;
    v.seed("Tailscale.peers", &many_peers(25))?;
    let list = v.panel_one("ts-peer-list")?;
    let overflow = v.number(list, "contentHeight")? > v.number(list, "height")?;
    v.check("devices-overflow", overflow, json!([v.get(list, "contentHeight")?, v.get(list, "height")?]));
    v.check("devices-clip", v.flag(list, "clip")?, v.get(list, "clip")?);
    let at25 = v.number("pop.panel", "height")?;
    v.seed("Tailscale.peers", &many_peers(50))?;
    let at50 = v.number("pop.panel", "height")?;
    v.check("devices-capped", (at50 - at25).abs() < 1.0, json!({ "25": at25, "50": at50 }));
    v.seed("Tailscale.peers", &tailnet_peers())?;
    v.invoke(v.panel_one("ts-exit-row-entry")?, "clicked", json!([]))?;
    v.set("Tailscale", "recommendedExitNodeId", json!(""))?;
    let exits = |from: usize, to: usize| -> Value {
        Value::Array(
            (from..to)
                .map(|i| json!({ "hostName": format!("exit-{i}"), "displayName": format!("exit-{i}"), "nodeId": format!("nE{i}CNTRL") }))
                .collect(),
        )
    };
    v.seed("Tailscale.exitNodes", &exits(0, 20))?;
    let scroll = v.panel_one("ts-exit-scroll")?;
    let overflow = v.number(scroll, "contentHeight")? > v.number(scroll, "height")?;
    v.check("exit-overflow", overflow, json!([v.get(scroll, "contentHeight")?, v.get(scroll, "height")?]));
    v.check("exit-clip", v.flag(scroll, "clip")?, v.get(scroll, "clip")?);
    let at20 = v.number("pop.panel", "height")?;
    for row in exits(20, 40).as_array().into_iter().flatten() {
        v.invoke("Tailscale.exitNodes", "append", json!([row]))?;
    }
    let at40 = v.number("pop.panel", "height")?;
    v.check("exit-capped", (at40 - at20).abs() < 1.0, json!({ "20": at20, "40": at40 }));
    let search = v.y_in_panel(v.panel_one("ts-exit-search")?)?;
    let scrolled = v.y_in_panel(scroll)?;
    v.check("search-above", search < scrolled, json!({ "search": search, "scroll": scrolled }));
    Ok(())
}

/// R-GROUP-06's delegate half: a delegate survives a re-sort, a join and a
/// leave, and a rebuild makes a new one.
pub fn group_06_delegates_survive(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.seed("Tailscale.peers", &three())?;
    v.set("pop", "expanded", json!("devices"))?;
    let list = v.panel_one("ts-peer-list")?;
    v.require(v.number(list, "count")? == 3.0, "the view has the 3 seeded rows")?;
    let target = v.row_of_node_id(list, "nBBB1CNTRL")?.ok_or("precondition: a delegate for bravo")?;
    v.invoke(target, "clicked", json!([]))?;
    v.require(v.flag(target, "copied")?, "the delegate took the local state")?;
    v.invoke("Tailscale.peers", "setProperty", json!([0, "online", false]))?;
    v.invoke("Tailscale.peers", "move", json!([0, 2, 1]))?;
    v.invoke("Tailscale.peers", "setProperty", json!([1, "ip4", "100.64.0.9"]))?;
    v.require(v.number(list, "count")? == 3.0, "the update left 3 rows")?;
    let after = v.row_of_node_id(list, "nBBB1CNTRL")?;
    v.check("resort-same", after == Some(target), json!(after.map(|e| e.0)));
    v.check("resort-state", v.flag(target, "copied")?, v.get(target, "copied")?);
    let alpha = v.row_of_node_id(list, "nAAA1CNTRL")?.ok_or("precondition: a delegate for alpha")?;
    v.check("alpha-offline", v.get(alpha, "online")? == json!(false), v.get(alpha, "online")?);
    let first = v.invoke(list, "itemAtIndex", json!([0]))?;
    let last = v.invoke(list, "itemAtIndex", json!([2]))?;
    let landed = first == json!({ "handle": target.0 }) && last == json!({ "handle": alpha.0 });
    v.require(landed, "the move landed: bravo first and alpha last")?;
    let gamma = v.row_of_node_id(list, "nCCC1CNTRL")?.ok_or("precondition: a delegate for gamma")?;
    let ips = json!([v.get(gamma, "ip4")?, v.get(target, "ip4")?]);
    v.check("own-updates", ips == json!(["100.64.0.9", "100.64.0.2"]), ips);
    let delta = json!({ "hostName": "delta", "displayName": "delta", "ip4": "100.64.0.4",
                        "ip6": "fd7a:115c:a1e0::4", "dnsName": "delta.example-tailnet.ts.net", "online": true,
                        "group": 0, "ownerName": "owner@example.com", "nodeId": "nDDD1CNTRL",
                        "exitNodeOption": false });
    v.invoke("Tailscale.peers", "insert", json!([0, delta]))?;
    v.require(v.number(list, "count")? == 4.0, "the insert landed")?;
    let joined = v.row_of_node_id(list, "nBBB1CNTRL")?;
    v.check("join-same", joined == Some(target), json!(joined.map(|e| e.0)));
    v.check("join-state", v.flag(target, "copied")?, v.get(target, "copied")?);
    v.invoke("Tailscale.peers", "remove", json!([0]))?;
    v.require(v.number(list, "count")? == 3.0, "the remove landed")?;
    let left = v.row_of_node_id(list, "nBBB1CNTRL")?;
    v.check("leave-same", left == Some(target), json!(left.map(|e| e.0)));
    v.check("leave-state", v.flag(target, "copied")?, v.get(target, "copied")?);
    v.seed("Tailscale.peers", &three())?;
    let rebuilt = v.row_of_node_id(list, "nBBB1CNTRL")?.ok_or("precondition: the rebuild has a bravo row")?;
    v.check("rebuild-new", rebuilt != target, json!(rebuilt.0));
    v.check("rebuild-fresh", !v.flag(rebuilt, "copied")?, v.get(rebuilt, "copied")?);
    Ok(())
}
