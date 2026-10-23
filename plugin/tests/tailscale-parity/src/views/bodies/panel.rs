//! The panel's root card: R-QML-05 to R-QML-08, R-QML-23 and R-UI-16's
//! view half (`tests/tailscale-qml-test.qml:517-582` at a38dbca).

use serde_json::{json, Value};

use crate::views::{El, Views};

const NODE: &str = "pentest-exit-node";
const DAY_MS: f64 = 86_400_000.0;

/// `name` is visible in `Running`, as setup; then `NoState` hides it; then
/// `Running` again.
fn hidden_in_no_state(v: &mut Views, id: &str, names: &[&str]) -> Result<(), String> {
    for name in names {
        v.require(!v.panel_shown(name)?.is_empty(), &format!("{name} is shown in Running"))?;
    }
    v.set("Tailscale", "state", json!({ "enum": "NoState" }))?;
    for name in names {
        let n = v.panel_shown(name)?.len();
        v.check(&format!("{id}-{name}"), n == 0, json!(n));
    }
    v.set("Tailscale", "state", json!({ "enum": "Running" }))
}

/// R-QML-05: nothing last-known while NoState, and each state's phrase.
pub fn qml_05_nothing_last_known(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    let open = v.flag("pop", "open")?;
    v.require(open, "the panel opens when PopoverManager names it")?;
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(false)), ("exitNodeName", json!(NODE))])?;
    hidden_in_no_state(v, "blocked", &["ts-self-ip4", "ts-blocked-alert"])?;
    v.set("Tailscale", "state", json!({ "enum": "NoState" }))?;
    let state = v.text(v.panel_one("ts-state")?, "text")?;
    v.check("no-daemon", state == "no daemon", json!(state));
    v.connected()?;
    v.invoke(v.panel_one("ts-devices-row")?, "clicked", json!([]))?;
    hidden_in_no_state(v, "devices", &["ts-peer", "ts-devices-card"])?;
    v.invoke(v.panel_one("ts-exit-row-entry")?, "clicked", json!([]))?;
    hidden_in_no_state(v, "exit", &["ts-exit-card"])?;
    v.invoke(v.panel_one("ts-settings-row")?, "clicked", json!([]))?;
    hidden_in_no_state(v, "settings", &["ts-settings-card"])?;
    v.set("Tailscale", "issues", json!(["DNS is not working"]))?;
    hidden_in_no_state(v, "health", &["ts-issue", "ts-issue-count"])?;
    v.set("Tailscale", "issues", json!([]))?;
    let phrases = [
        ("NeedsMachineAuth", "waiting for machine approval"),
        ("NeedsLogin", "logged out"),
        ("Stopped", "not connected"),
        ("Starting", "starting…"),
        ("Running", "connected"),
    ];
    for (state, phrase) in phrases {
        v.set("Tailscale", "state", json!({ "enum": state }))?;
        let text = v.text(v.panel_one("ts-state")?, "text")?;
        v.check(&format!("phrase-{state}"), text == phrase, json!(text));
    }
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(false)), ("exitNodeName", json!(NODE))])?;
    let text = v.text(v.panel_one("ts-state")?, "text")?;
    v.check("phrase-blocked", text == "exit node unreachable", json!(text));
    Ok(())
}

/// R-QML-06: the key-expiry line, against the wall clock the view reads,
/// with each offset in the middle of a day and the margin checked.
pub fn qml_06_key_expiry(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    v.set("Tailscale", "keyExpiry", Value::Null)?;
    v.check("unset-hidden", v.panel_shown("ts-expiry")?.is_empty(), json!(v.panel_shown("ts-expiry")?.len()));
    let n = v.now()?;
    let cases = [
        (548.5, "expires in 18 months"),
        (30.5, "expires in 1 month"),
        (5.5, "expires in 5 days"),
        (1.5, "expires in 1 day"),
        (0.5, "expires in under a day"),
        (-0.5, "session expired"),
    ];
    for (days, want) in cases {
        v.set("Tailscale", "keyExpiry", json!({ "date_ms": n + days * DAY_MS }))?;
        let line = v.panel_one("ts-expiry")?;
        let text = v.text(line, "text")?;
        v.check(&format!("{days}-days"), v.flag(line, "visible")? && text == want, json!(text));
        let drift = (v.now()? - n).abs();
        v.check(&format!("{days}-days-margin"), drift < DAY_MS / 2.0, json!(drift));
        if days == 548.5 {
            let colour = v.get(line, "color")?;
            v.check("disabled-colour", colour == v.theme("textDisabled")?, colour);
        }
    }
    Ok(())
}

/// R-QML-07: one plain-text line per issue, and the count row.
pub fn qml_07_health_issues(v: &mut Views) -> Result<(), String> {
    let warning = "Some peers are advertising routes but --accept-routes is false.";
    v.connected_with_peers()?;
    v.open_panel()?;
    v.set("Tailscale", "issues", json!([warning]))?;
    let issues = v.panel_shown("ts-issue")?;
    v.check("one-issue", issues.len() == 1, json!(issues.len()));
    if let Some(issue) = issues.first().copied() {
        v.check("verbatim", v.text(issue, "text")? == warning, v.get(issue, "text")?);
        v.check("plain", v.get(issue, "textFormat")? == v.get("Text", "PlainText")?, v.get(issue, "textFormat")?);
    }
    let title = v.get(v.panel_one("ts-issue-count")?, "title")?;
    v.check("count-row", title == json!("1 issue detected…"), title);
    Ok(())
}

/// R-QML-08: the blocked alert names the node, as plain text, above "this
/// device".
pub fn qml_08_blocked_alert(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(false)), ("exitNodeName", json!(NODE))])?;
    let alert = v.panel_one("ts-blocked-alert")?;
    v.check("shown", v.flag(alert, "visible")?, v.get(alert, "visible")?);
    let text = v.panel_one("ts-blocked-text")?;
    v.check("names-node", v.text(text, "text")?.contains(NODE), v.get(text, "text")?);
    v.check("plain", v.get(text, "textFormat")? == v.get("Text", "PlainText")?, v.get(text, "textFormat")?);
    let alert_y = v.y_in_panel(alert)?;
    let first_y = v.y_in_panel(v.panel_one("ts-self-name")?)?;
    v.check("above-this-device", alert_y < first_y, json!({ "alert": alert_y, "this-device": first_y }));
    Ok(())
}

/// R-QML-23: this device's identity rows.
pub fn qml_23_identity_rows(v: &mut Views) -> Result<(), String> {
    v.connected_with_peers()?;
    v.open_panel()?;
    let name = v.panel_one("ts-self-name")?;
    let plain = v.get("Text", "PlainText")?;
    let mut omega = false;
    for o in v.find(name, None)? {
        let is_text = v.get(o, "text") == Ok(json!("omega")) && v.get(o, "textFormat").ok() == Some(plain.clone());
        omega |= is_text && v.flag(o, "visible")?;
    }
    v.check("self-name", omega, v.get(name, "title")?);
    let ip4 = v.panel_one("ts-self-ip4")?;
    v.check("ip4-title", v.get(ip4, "title")? == json!("100.115.228.122"), v.get(ip4, "title")?);
    v.set("Quickshell", "clipboardText", json!(""))?;
    v.invoke(ip4, "clicked", json!([]))?;
    let clip = v.get("Quickshell", "clipboardText")?;
    v.check("ip4-copies", clip == json!("100.115.228.122"), clip);
    Ok(())
}

/// The panel's visible Texts and the Texts inside its tooltips, which the
/// Tooltip stand-in never shows, whose text contains `a` or `b`, by name.
fn explanations(v: &Views, a: &str, b: &str) -> Result<Vec<String>, String> {
    let mut tooltips: Vec<El> = Vec::new();
    for o in v.find("pop", None)? {
        if v.get(o, "anchorItem").is_ok() && v.get(o, "panelRadius").is_ok() {
            tooltips.extend(v.find(o, None)?);
        }
    }
    v.require(!tooltips.is_empty(), "the panel has a tooltip whose Texts are counted")?;
    let mut named = Vec::new();
    for o in v.find("pop", None)? {
        let (Ok(Value::String(text)), Ok(_)) = (v.get(o, "text"), v.get(o, "textFormat")) else { continue };
        let counted = v.flag(o, "visible")? || tooltips.contains(&o);
        if counted && (text.contains(a) || text.contains(b)) {
            named.push(v.text(o, "objectName")?);
        }
    }
    Ok(named)
}

/// R-UI-16's view half: one explanation when a read and a write both
/// failed, and the write's explanation back once the read recovers.
pub fn ui_16_one_explanation(v: &mut Views) -> Result<(), String> {
    let read = "/localapi/v0/status answered HTTP/1.1 403 Forbidden";
    let write = crate::views::ui::REFUSAL;
    v.connected()?;
    v.stage(&[
        ("state", json!({ "enum": "NoState" })),
        ("readError", json!(read)),
        ("writeError", json!(write)),
        ("writable", json!(false)),
    ])?;
    v.open_panel()?;
    for card in ["", "exit", "settings"] {
        v.set("pop", "expanded", json!(card))?;
        let named = explanations(v, read, write)?;
        let id = if card.is_empty() { "one-explanation".to_string() } else { format!("one-explanation-{card}-open") };
        v.check(&id, named == ["ts-read-error"], json!(named));
    }
    v.set("pop", "expanded", json!(""))?;
    let line = v.text(v.panel_one("ts-read-error")?, "text")?;
    v.check("read-error-verbatim", line == read, json!(line));
    let tip = v.text(v.panel_one("ts-connect-tip")?, "text")?;
    v.check("tip-not-answering", tip == "tailscaled is not answering, so there is nothing to ask", json!(tip));
    v.stage(&[("readError", json!("")), ("state", json!({ "enum": "Running" }))])?;
    let tip = v.text(v.panel_one("ts-connect-tip")?, "text")?;
    v.check("tip-has-write-error", tip.contains(write), json!(tip));
    let line = v.get(v.panel_one("ts-read-error")?, "visible")?;
    v.check("read-error-hidden", line == json!(false), line);
    Ok(())
}
