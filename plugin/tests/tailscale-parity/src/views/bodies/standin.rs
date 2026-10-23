//! The stand-ins themselves: R-QML-25 (the `Tailscale` stand-in behaves
//! like the contract) and R-QML-27 (the theme tokens the views read).

use serde_json::{json, Map, Value};

use crate::views::ui::tailnet_peers;
use crate::views::Views;

/// The stand-in's properties beside the two models, which a snapshot
/// compares by value.
const VALUES: &[&str] = &[
    "state",
    "exitNodeActive",
    "exitNodeOnline",
    "exitNodeId",
    "exitNodeName",
    "exitNodeBlocked",
    "issues",
    "issueCount",
    "selfName",
    "selfIp4",
    "selfIp6",
    "selfDnsName",
    "tailnet",
    "keyExpiry",
    "recommendedExitNodeId",
    "writable",
    "writeError",
    "readError",
    "wantRunning",
    "exitNodeAllowLANAccess",
    "acceptRoutes",
    "acceptDns",
];

/// Every value property, and each model's row count.
fn snapshot(v: &Views) -> Result<Value, String> {
    let mut out = Map::new();
    for name in VALUES {
        out.insert(name.to_string(), v.get("Tailscale", name)?);
    }
    for model in ["peers", "exitNodes"] {
        out.insert(format!("{model}.count"), v.get(format!("Tailscale.{model}").as_str(), "count")?);
    }
    Ok(Value::Object(out))
}

const MODEL_SIGNALS: &[&str] = &["dataChanged", "rowsMoved", "rowsInserted", "rowsRemoved", "modelReset"];

/// How often each model signal of `peers` fired since it was watched.
fn fired(v: &Views) -> Result<Value, String> {
    let mut out = Map::new();
    for s in MODEL_SIGNALS {
        out.insert(s.to_string(), json!(v.fired("Tailscale.peers", s)?));
    }
    Ok(Value::Object(out))
}

/// R-QML-25: a fresh stand-in, its actions, its derived members and its
/// models' row signals.
pub fn qml_25_stand_in(v: &mut Views) -> Result<(), String> {
    let state = v.get("Tailscale", "state")?;
    let fresh = state == v.get("Tailscale", "NoState")? && v.flag("Tailscale", "writable")?;
    v.check("fresh", fresh, json!({ "state": state, "writable": v.get("Tailscale", "writable")? }));
    let actions = [
        ("setWantRunning", json!([true]), "setWantRunning(true)"),
        ("setExitNode", json!(["nAAA1CNTRL"]), "setExitNode(nAAA1CNTRL)"),
        ("setExitNodeAllowLANAccess", json!([true]), "setExitNodeAllowLANAccess(true)"),
        ("setAcceptRoutes", json!([true]), "setAcceptRoutes(true)"),
        ("setAcceptDns", json!([true]), "setAcceptDns(true)"),
    ];
    v.take_calls()?;
    for (name, args, recorded) in actions {
        let before = snapshot(v)?;
        v.invoke("Tailscale", name, args)?;
        let calls = v.calls()?;
        v.check(&format!("{name}-records-one"), calls == recorded, json!(calls));
        let after = snapshot(v)?;
        v.check(&format!("{name}-moves-nothing"), after == before, after);
    }
    v.stage(&[("exitNodeActive", json!(true)), ("exitNodeOnline", json!(false))])?;
    v.check("blocked-derived", v.flag("Tailscale", "exitNodeBlocked")?, v.get("Tailscale", "exitNodeBlocked")?);
    v.set("Tailscale", "issues", json!(["a", "b"]))?;
    v.check("issue-count-derived", v.get("Tailscale", "issueCount")? == json!(2), v.get("Tailscale", "issueCount")?);
    row_signals(v)
}

/// On `peers` with three rows, each edit is its own row signal and never a
/// reset; a clear and refill gives every row a new delegate.
fn row_signals(v: &mut Views) -> Result<(), String> {
    let rows = tailnet_peers();
    v.seed("Tailscale.peers", &json!([rows[0], rows[1], rows[2]]))?;
    v.set("pop", "expanded", json!("devices"))?;
    v.connected()?;
    for s in MODEL_SIGNALS {
        v.watch("Tailscale.peers", s)?;
    }
    let edits = [
        ("setProperty", json!([0, "online", false]), "dataChanged"),
        ("move", json!([0, 2, 1]), "rowsMoved"),
        ("insert", json!([0, rows[3]]), "rowsInserted"),
        ("remove", json!([0]), "rowsRemoved"),
    ];
    let mut want = json!({ "dataChanged": 0, "rowsMoved": 0, "rowsInserted": 0, "rowsRemoved": 0, "modelReset": 0 });
    for (edit, args, signal) in edits {
        v.invoke("Tailscale.peers", edit, args)?;
        want[signal] = json!(1);
        let got = fired(v)?;
        v.check(&format!("{edit}-is-{signal}"), got == want, got);
    }
    v.open_panel()?;
    let list = v.panel_one("ts-peer-list")?;
    let ids: Vec<&str> = (0..3).filter_map(|i| rows[i]["nodeId"].as_str()).collect();
    let mut before = Vec::new();
    for id in &ids {
        before.push(v.row_of_node_id(list, id)?.ok_or("precondition: a delegate for each row")?);
    }
    v.invoke("Tailscale.peers", "clear", json!([]))?;
    let count = v.get("Tailscale.peers", "count")?;
    v.check("clear-empties", count == json!(0), count);
    for row in &rows.as_array().ok_or("rows")?[..3] {
        v.invoke("Tailscale.peers", "append", json!([row]))?;
    }
    let mut reused = Vec::new();
    for id in &ids {
        let after = v.row_of_node_id(list, id)?.ok_or("precondition: a delegate for each refilled row")?;
        if before.contains(&after) {
            reused.push(*id);
        }
    }
    v.check("refill-new-delegates", reused.is_empty(), json!(reused));
    Ok(())
}

/// R-QML-27: the theme stand-in carries the tokens the views read; the
/// `.qml:` rule fails the run on any binding that reads one it lacks.
pub fn qml_27_theme_tokens(v: &mut Views) -> Result<(), String> {
    let tokens = [
        "accentFillActive",
        "accentFillSoft",
        "accentBorderSoft",
        "powerHover",
        "radiusSlot",
        "radiusMenu",
        "radiusMenuRow",
        "pillHeight",
        "pillRadius",
    ];
    for token in tokens {
        let got = v.get("Theme", token);
        let defined = got.as_ref().is_ok_and(|t| t != &json!({ "undefined": true }) && !t.is_null());
        v.check(&format!("token-{token}"), defined, json!(got.unwrap_or_else(|e| json!(e))));
    }
    v.connected_with_peers()?;
    v.open_panel()?;
    for card in ["devices", "exit", "settings"] {
        v.set("pop", "expanded", json!(card))?;
    }
    Ok(())
}
