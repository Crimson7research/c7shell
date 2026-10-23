//! The write-backed controls: R-QML-20 to R-QML-22 and R-WRITE-09's toggle
//! half (`tests/tailscale-qml-test.qml:1223-1660` at a38dbca).

use serde_json::json;

use crate::views::ui::{exit_nodes, REFUSAL};
use crate::views::{El, Views};

const TRANSIENT: &str = "the connection closed before the response headers";

/// Whether `o`'s title is drawn in `Theme.textDisabled` and it does not
/// light up under the pointer.
fn dead(v: &Views, o: El) -> Result<bool, String> {
    Ok(v.get(o, "titleColor")? == v.theme("textDisabled")? && !v.flag(o, "hoverable")?)
}

/// The number of calls in a `calls()` reading.
fn count(calls: &str) -> usize {
    calls.split_whitespace().count()
}

/// Connected, writable, three exit nodes, the panel open.
fn live_panel(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.stage(&[
        ("writable", json!(true)),
        ("writeError", json!("")),
        ("acceptRoutes", json!(false)),
        ("acceptDns", json!(false)),
    ])?;
    v.seed("Tailscale.exitNodes", &exit_nodes())?;
    v.set("Tailscale", "recommendedExitNodeId", json!("nCCC1CNTRL"))?;
    v.open_panel()
}

/// The exit card's half of R-QML-20, after `writable` and `writeError` are
/// staged: `refused` says which reading to expect.
fn exit_card(v: &mut Views, id: &str, refused: bool) -> Result<(), String> {
    v.set("pop", "expanded", json!("exit"))?;
    let label = v.text(v.panel_one("ts-exit-all-label")?, "text")?;
    v.check(&format!("{id}-label"), label.contains("read-only") == refused, json!(label));
    let why = v.panel_shown("ts-exit-write-error")?;
    let texts = v.each(&why, "text")?;
    let explained =
        why.len() == 1 && texts[0].as_str().is_some_and(|t| t.contains(REFUSAL) && t.contains("c7shell-bootstrap"));
    v.check(&format!("{id}-exit-why"), explained == refused && (refused || why.is_empty()), texts);
    let rows = v.panel_shown("ts-exit-row")?;
    v.check(&format!("{id}-three-rows"), rows.len() == 3, json!(rows.len()));
    let mut all = true;
    for o in &rows {
        all &= dead(v, *o)? == refused;
    }
    v.check(&format!("{id}-rows"), all, v.each(&rows, "titleColor")?);
    let lan = v.panel_one("ts-exit-lan-switch")?;
    v.check(&format!("{id}-lan-switch"), v.flag(lan, "enabled")? != refused, v.get(lan, "enabled")?);
    v.take_calls()?;
    if let Some(row) = rows.first().copied() {
        v.invoke(row, "clicked", json!([]))?;
    }
    v.invoke(v.panel_one("ts-exit-none")?, "clicked", json!([]))?;
    v.invoke(v.panel_one("ts-exit-lan")?, "clicked", json!([]))?;
    let calls = v.calls()?;
    let want = if refused { 0 } else { 3 };
    v.check(&format!("{id}-exit-clicks"), count(&calls) == want, json!(calls));
    Ok(())
}

/// The settings card's half of R-QML-20.
fn settings_card(v: &mut Views, id: &str, refused: bool) -> Result<(), String> {
    v.set("pop", "expanded", json!("settings"))?;
    let why = v.panel_shown("ts-settings-write-error")?;
    let texts = v.each(&why, "text")?;
    let explained =
        why.len() == 1 && texts[0].as_str().is_some_and(|t| t.contains(REFUSAL) && t.contains("c7shell-bootstrap"));
    v.check(&format!("{id}-settings-why"), explained == refused && (refused || why.is_empty()), texts);
    for name in ["ts-settings-routes", "ts-settings-dns"] {
        let row = v.panel_one(name)?;
        v.check(&format!("{id}-{name}"), dead(v, row)? == refused, v.get(row, "titleColor")?);
        let switch = v.panel_one(&format!("{name}-switch"))?;
        v.check(&format!("{id}-{name}-switch"), v.flag(switch, "enabled")? != refused, v.get(switch, "enabled")?);
    }
    v.take_calls()?;
    v.invoke(v.panel_one("ts-settings-routes")?, "clicked", json!([]))?;
    v.invoke(v.panel_one("ts-settings-dns")?, "clicked", json!([]))?;
    let calls = v.calls()?;
    let want = if refused { 0 } else { 2 };
    v.check(&format!("{id}-settings-clicks"), count(&calls) == want, json!(calls));
    Ok(())
}

/// R-QML-20: controls go dead after a 403 and come back, and a transient
/// failure leaves them live.
pub fn qml_20_dead_after_a_refusal(v: &mut Views) -> Result<(), String> {
    live_panel(v)?;
    exit_card(v, "writable", false)?;
    settings_card(v, "writable", false)?;
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL))])?;
    exit_card(v, "refused", true)?;
    settings_card(v, "refused", true)?;
    v.stage(&[("writable", json!(true)), ("writeError", json!(""))])?;
    exit_card(v, "restored", false)?;
    settings_card(v, "restored", false)?;
    v.stage(&[("writable", json!(true)), ("writeError", json!(TRANSIENT))])?;
    let why = v.panel_shown("ts-settings-write-error")?;
    let texts = v.each(&why, "text")?;
    let line =
        why.len() == 1 && texts[0].as_str().is_some_and(|t| t.contains(TRANSIENT) && !t.contains("c7shell-bootstrap"));
    v.check("transient-line", line, texts);
    let mut live = true;
    for name in ["ts-settings-routes-switch", "ts-settings-dns-switch"] {
        live &= v.flag(v.panel_one(name)?, "enabled")?;
    }
    v.check("transient-live", live, json!(live));
    v.take_calls()?;
    v.invoke(v.panel_one("ts-settings-routes")?, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("transient-click-sends", count(&calls) == 1, json!(calls));
    Ok(())
}

/// R-QML-21: the settings sub-card, its switches read back, and the
/// explanation of the suppressed warning beside accept routes.
pub fn qml_21_settings(v: &mut Views) -> Result<(), String> {
    live_panel(v)?;
    v.set("pop", "expanded", json!(""))?;
    let on_root = v.panel_shown("ts-settings-routes")?.len();
    v.check("not-on-root", on_root == 0, json!(on_root));
    v.set("Tailscale", "acceptDns", json!(true))?;
    v.invoke(v.panel_one("ts-settings-row")?, "clicked", json!([]))?;
    let routes = v.panel_one("ts-settings-routes")?;
    let routes_switch = v.panel_one("ts-settings-routes-switch")?;
    v.check("routes-reads-false", !v.flag(routes_switch, "checked")?, v.get(routes_switch, "checked")?);
    v.require(v.panel_shown("ts-issue")?.is_empty(), "the issue list is empty")?;
    let why = v.panel_shown("ts-settings-routes-why")?;
    v.check("why-shown", why.len() == 1, json!(why.len()));
    if let Some(w) = why.first().copied() {
        let text = v.text(w, "text")?;
        v.check("why-mentions-route", text.to_lowercase().contains("route"), json!(text));
        v.check("why-plain", v.get(w, "textFormat")? == v.get("Text", "PlainText")?, v.get(w, "textFormat")?);
        let (wy, ry) = (v.y_in_panel(w)?, v.y_in_panel(routes)?);
        v.check("why-below-routes", wy > ry, json!({ "why": wy, "routes": ry }));
    }
    v.set("Tailscale", "acceptRoutes", json!(true))?;
    let hidden = v.panel_shown("ts-settings-routes-why")?.len();
    v.check("why-hidden-when-on", hidden == 0, json!(hidden));
    v.set("Tailscale", "acceptRoutes", json!(false))?;
    let back = v.panel_shown("ts-settings-routes-why")?.len();
    v.check("why-back-when-off", back == 1, json!(back));
    switches(v, routes, routes_switch)?;
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL))])?;
    let kept = v.panel_shown("ts-settings-routes-why")?.len();
    v.check("why-stays-after-refusal", kept == 1, json!(kept));
    Ok(())
}

/// The routes and DNS switches ask for the opposite of what the daemon
/// holds, and move only when it reports.
fn switches(v: &mut Views, routes: El, routes_switch: El) -> Result<(), String> {
    v.take_calls()?;
    v.invoke(routes, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("routes-asks-true", calls == "setAcceptRoutes(true)", json!(calls));
    v.check("routes-waits", !v.flag(routes_switch, "checked")?, v.get(routes_switch, "checked")?);
    v.set("Tailscale", "acceptRoutes", json!(true))?;
    v.check("routes-follows", v.flag(routes_switch, "checked")?, v.get(routes_switch, "checked")?);
    v.invoke(routes, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("routes-asks-false", calls == "setAcceptRoutes(false)", json!(calls));
    v.set("Tailscale", "acceptRoutes", json!(false))?;
    let dns = v.panel_one("ts-settings-dns")?;
    let dns_switch = v.panel_one("ts-settings-dns-switch")?;
    v.check("dns-reads-true", v.flag(dns_switch, "checked")?, v.get(dns_switch, "checked")?);
    v.invoke(dns, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("dns-asks-false", calls == "setAcceptDns(false)", json!(calls));
    v.check("dns-waits", v.flag(dns_switch, "checked")?, v.get(dns_switch, "checked")?);
    v.set("Tailscale", "acceptDns", json!(false))?;
    v.check("dns-follows", !v.flag(dns_switch, "checked")?, v.get(dns_switch, "checked")?);
    Ok(())
}

/// The connect toggle's enabled and checked, as JSON.
fn toggle_state(v: &Views, toggle: El) -> Result<serde_json::Value, String> {
    Ok(json!({ "enabled": v.get(toggle, "enabled")?, "checked": v.get(toggle, "checked")? }))
}

/// R-QML-22: the connect toggle follows `wantRunning`, not `state`.
pub fn qml_22_connect_toggle(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.stage(&[("writable", json!(true)), ("writeError", json!("")), ("wantRunning", json!(true))])?;
    v.open_panel()?;
    let toggle = v.panel_one("ts-connect-toggle")?;
    let tip = v.panel_one("ts-connect-tip")?;
    let on = json!({ "enabled": true, "checked": true });
    v.check("opens-on", toggle_state(v, toggle)? == on, toggle_state(v, toggle)?);
    let text = v.text(tip, "text")?;
    v.check("tip-on", text.contains("a session reached over tailscale ends with it"), json!(text));
    for state in ["Starting", "NeedsLogin"] {
        v.set("Tailscale", "state", json!({ "enum": state }))?;
        v.check(&format!("checked-in-{state}"), v.flag(toggle, "checked")?, v.get(toggle, "checked")?);
    }
    v.connected()?;
    v.take_calls()?;
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("asks-false", calls == "setWantRunning(false)", json!(calls));
    v.check("waits-for-the-daemon", v.flag(toggle, "checked")?, v.get(toggle, "checked")?);
    v.set("Tailscale", "wantRunning", json!(false))?;
    v.check("follows-false", !v.flag(toggle, "checked")?, v.get(toggle, "checked")?);
    let text = v.text(tip, "text")?;
    v.check("tip-off", text == "connect to the tailnet", json!(text));
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("asks-true", calls == "setWantRunning(true)", json!(calls));
    v.stage(&[("wantRunning", json!(true)), ("state", json!({ "enum": "NoState" }))])?;
    v.check("no-daemon-disabled", !v.flag(toggle, "enabled")?, v.get(toggle, "enabled")?);
    let text = v.text(tip, "text")?;
    v.check("tip-no-daemon", text == "tailscaled is not answering, so there is nothing to ask", json!(text));
    v.take_calls()?;
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("no-daemon-sends-nothing", calls.is_empty(), json!(calls));
    v.connected()?;
    v.check("back-on", toggle_state(v, toggle)? == on, toggle_state(v, toggle)?);
    refused_toggle(v, toggle, tip)
}

/// After a 403 the toggle is dead and says why; once writable again it is
/// live and asks once.
fn refused_toggle(v: &mut Views, toggle: El, tip: El) -> Result<(), String> {
    v.stage(&[("writable", json!(false)), ("writeError", json!(REFUSAL)), ("readError", json!(""))])?;
    v.check("refused-disabled", !v.flag(toggle, "enabled")?, v.get(toggle, "enabled")?);
    v.take_calls()?;
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("refused-sends-nothing", calls.is_empty(), json!(calls));
    let text = v.text(tip, "text")?;
    v.check("tip-says-why", text.contains(REFUSAL), json!(text));
    v.stage(&[("writable", json!(true)), ("writeError", json!(""))])?;
    v.check("restored-enabled", v.flag(toggle, "enabled")?, v.get(toggle, "enabled")?);
    let text = v.text(tip, "text")?;
    v.check("tip-cleared", !text.contains(REFUSAL) && !text.is_empty(), json!(text));
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("restored-asks-once", count(&calls) == 1, json!(calls));
    Ok(())
}

/// R-WRITE-09's toggle half: stopped by the daemon after a disconnect, the
/// toggle is live and unchecked, and asks to connect.
pub fn write_09_toggle_after_disconnect(v: &mut Views) -> Result<(), String> {
    v.connected()?;
    v.stage(&[("writable", json!(true)), ("writeError", json!("")), ("wantRunning", json!(true))])?;
    v.open_panel()?;
    v.stage(&[("wantRunning", json!(false)), ("state", json!({ "enum": "Stopped" }))])?;
    let toggle = v.panel_one("ts-connect-toggle")?;
    let off = json!({ "enabled": true, "checked": false });
    v.check("enabled-unchecked", toggle_state(v, toggle)? == off, toggle_state(v, toggle)?);
    v.take_calls()?;
    v.invoke(toggle, "toggled", json!([]))?;
    let calls = v.calls()?;
    v.check("asks-to-connect", calls == "setWantRunning(true)", json!(calls));
    Ok(())
}
