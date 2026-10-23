//! What the bodies share: finding the bar slot and the panel's elements by
//! their `ts-` names, the stand-in states the original suite stages, and
//! the peers it seeds (`tests/tailscale-qml-test.qml` at a38dbca, its
//! helpers at `:58-160` and `:385-515`).

use serde_json::{json, Value};

use super::{El, Views};

/// The four peers of the original suite (`:420-451`): two of mine, one
/// tagged, one of another user's whose OS hostname is `localhost`.
pub fn tailnet_peers() -> Value {
    json!([
        { "hostName": "tango", "displayName": "tango",
          "ip4": "100.119.215.89", "ip6": "fd7a:115c:a1e0::3016:83db",
          "dnsName": "tango.example-tailnet.ts.net", "online": true, "group": 0,
          "ownerName": "owner@example.com", "nodeId": "nAAA1CNTRL", "exitNodeOption": false },
        { "hostName": "yankee", "displayName": "yankee",
          "ip4": "100.81.62.41", "ip6": "",
          "dnsName": "yankee-with-a-long-magicdns-name.example-tailnet.ts.net", "online": false, "group": 0,
          "ownerName": "owner@example.com", "nodeId": "nBBB1CNTRL", "exitNodeOption": false },
        { "hostName": "pentest-exit-node", "displayName": "pentest-exit-node",
          "ip4": "100.124.183.145", "ip6": "fd7a:115c:a1e0::bff4:b239",
          "dnsName": "pentest-exit-node.example-tailnet.ts.net", "online": true, "group": 1,
          "ownerName": "Tagged Devices", "nodeId": "nCCC1CNTRL", "exitNodeOption": true },
        { "hostName": "localhost", "displayName": "workstation",
          "ip4": "100.70.33.83", "ip6": "fd7a:115c:a1e0::9ca4:f8a4",
          "dnsName": "workstation.example-tailnet.ts.net", "online": true, "group": 2,
          "ownerName": "Third Example", "nodeId": "nDDD1CNTRL", "exitNodeOption": false }
    ])
}

/// `n` peers of mine named `node-<i>`, the last another user's (`:1051-1061`).
pub fn many_peers(n: usize) -> Value {
    let rows: Vec<Value> = (0..n)
        .map(|i| {
            json!({ "hostName": format!("node-{i}"), "displayName": format!("node-{i}"),
                    "ip4": format!("100.64.1.{i}"), "ip6": "",
                    "dnsName": format!("node-{i}.example-tailnet.ts.net"), "online": true,
                    "group": if i == n - 1 { 2 } else { 0 }, "ownerName": "Third Example",
                    "nodeId": format!("n{i}0CNTRL"), "exitNodeOption": false })
        })
        .collect();
    Value::Array(rows)
}

/// The three exit nodes of the original suite (`:1504-1514`): two share a
/// hostname, and the first of those is recommended.
pub fn exit_nodes() -> Value {
    json!([
        { "hostName": "ip-172-31-0-10", "displayName": "host-5", "nodeId": "nEEE1CNTRL" },
        { "hostName": "pentest-exit-node", "displayName": "pentest-exit-node", "nodeId": "nCCC1CNTRL" },
        { "hostName": "pentest-exit-node", "displayName": "pentest-exit-node", "nodeId": "nFFF1CNTRL" }
    ])
}

/// The refusal the original suite stages.
pub const REFUSAL: &str = "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden";

impl Views {
    /// Sets each of `values` on the stand-in, in order.
    pub fn stage(&mut self, values: &[(&str, Value)]) -> Result<(), String> {
        values.iter().try_for_each(|(name, v)| self.set("Tailscale", name, v.clone()))
    }

    /// `Running`, no issues and no exit node (`connected()`, `:159-165`).
    pub fn connected(&mut self) -> Result<(), String> {
        self.stage(&[
            ("state", json!({ "enum": "Running" })),
            ("issues", json!([])),
            ("exitNodeActive", json!(false)),
            ("exitNodeOnline", json!(false)),
            ("exitNodeName", json!("")),
        ])
    }

    /// Connected, this device named, and the four peers seeded
    /// (`connectedWithPeers()`, `:506-515`).
    pub fn connected_with_peers(&mut self) -> Result<(), String> {
        self.connected()?;
        self.stage(&[
            ("selfName", json!("omega")),
            ("selfIp4", json!("100.115.228.122")),
            ("selfIp6", json!("fd7a:115c:a1e0::fd27:82d8")),
            ("selfDnsName", json!("omega.example-tailnet.ts.net")),
            ("tailnet", json!("example-tailnet.ts.net")),
        ])?;
        self.seed("Tailscale.peers", &tailnet_peers())
    }

    /// Clears the model `model` and appends `rows`: a rebuild, which
    /// discards every delegate (`seedPeers()`, `:453-456`).
    pub fn seed(&mut self, model: &str, rows: &Value) -> Result<(), String> {
        self.invoke(model, "clear", json!([]))?;
        for row in rows.as_array().ok_or("rows are no array")? {
            self.invoke(model, "append", json!([row]))?;
        }
        Ok(())
    }

    /// Opens the panel as the slot's click does.
    pub fn open_panel(&mut self) -> Result<(), String> {
        self.invoke("PopoverManager", "toggle", json!(["tailscale", null])).map(|_| ())
    }

    /// The recorded calls are taken, so the next read counts from here.
    pub fn take_calls(&mut self) -> Result<(), String> {
        self.calls().map(|_| ())
    }

    /// The bar slot, `objectName` `tailscale`; exactly one.
    pub fn slot(&self) -> Result<El, String> {
        one(self.find("pill", Some("tailscale"))?, "the bar slot `tailscale`")
    }

    /// Every element inside the slot.
    pub fn slot_parts(&self) -> Result<Vec<El>, String> {
        self.find(self.slot()?, None)
    }

    /// The visible slot parts whose `color` is `colour`.
    pub fn visible_of_colour(&self, colour: &str) -> Result<Vec<El>, String> {
        let mut hits = Vec::new();
        for o in self.slot_parts()? {
            if self.flag(o, "visible")? && self.get(o, "color").ok() == Some(json!(colour)) {
                hits.push(o);
            }
        }
        Ok(hits)
    }

    /// Whether a visible slot part's `text` is `s`.
    pub fn visible_text(&self, s: &str) -> Result<bool, String> {
        for o in self.slot_parts()? {
            if self.flag(o, "visible")? && self.get(o, "text").ok() == Some(json!(s)) {
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// The texts of the visible slot parts, for an actual value.
    pub fn slot_texts(&self) -> Result<Value, String> {
        let mut texts = Vec::new();
        for o in self.slot_parts()? {
            if let Ok(Value::String(t)) = self.get(o, "text") {
                texts.push(json!({ "text": t, "visible": self.flag(o, "visible")? }));
            }
        }
        Ok(Value::Array(texts))
    }

    /// The slot's implicit width after the layout barrier (`slotWidth()`,
    /// `:135-139`).
    pub fn slot_width(&self) -> Result<f64, String> {
        self.layout()?;
        self.number(self.slot()?, "implicitWidth")
    }

    /// The slot's one label: the part with `truncated` that is not the ✕.
    pub fn label(&self) -> Result<El, String> {
        let mut labels = Vec::new();
        for o in self.slot_parts()? {
            if self.get(o, "truncated").is_ok_and(|t| t.is_boolean()) && self.text(o, "text")? != "\u{2715}" {
                labels.push(o);
            }
        }
        one(labels, "a label in the slot")
    }

    /// The tint of the slot's one icon.
    pub fn icon_tint(&self) -> Result<Value, String> {
        let mut icons = Vec::new();
        for o in self.slot_parts()? {
            if self.get(o, "tint").is_ok_and(|t| t.is_string()) {
                icons.push(o);
            }
        }
        self.get(one(icons, "an Icon in the slot")?, "tint")
    }

    /// A theme colour, as the driver writes colours.
    pub fn theme(&self, name: &str) -> Result<Value, String> {
        self.get("Theme", name)
    }

    /// Every panel element named `name` (`panelAll()`).
    pub fn panel_all(&self, name: &str) -> Result<Vec<El>, String> {
        self.find("pop", Some(name))
    }

    /// The visible panel elements named `name` (`panelShown()`).
    pub fn panel_shown(&self, name: &str) -> Result<Vec<El>, String> {
        let mut shown = Vec::new();
        for o in self.panel_all(name)? {
            if self.flag(o, "visible")? {
                shown.push(o);
            }
        }
        Ok(shown)
    }

    /// The one panel element named `name` (`panelOne()`); an error when
    /// there is not exactly one.
    pub fn panel_one(&self, name: &str) -> Result<El, String> {
        one(self.panel_all(name)?, &format!("`{name}` in the panel"))
    }

    /// Member `name` of each of `els`, for an actual value.
    pub fn each(&self, els: &[El], name: &str) -> Result<Value, String> {
        els.iter().map(|o| self.get(*o, name)).collect::<Result<Vec<_>, _>>().map(Value::Array)
    }

    /// The `ts-peer` row whose `displayName` is `name` (`peerRow()`).
    pub fn peer_row(&self, name: &str) -> Result<El, String> {
        for o in self.panel_all("ts-peer")? {
            if self.get(o, "displayName")? == json!(name) {
                return Ok(o);
            }
        }
        Err(format!("no peer row for {name}"))
    }

    /// The delegate of `list` whose `nodeId` is `id`, if one exists
    /// (`rowOfNodeId()`).
    pub fn row_of_node_id(&mut self, list: El, id: &str) -> Result<Option<El>, String> {
        let count = self.number(list, "count")? as u64;
        for i in 0..count {
            if let Some(item) = self.invoke(list, "itemAtIndex", json!([i]))?.get("handle").and_then(Value::as_u64) {
                if self.get(El(item), "nodeId")? == json!(id) {
                    return Ok(Some(El(item)));
                }
            }
        }
        Ok(None)
    }

    /// Asks `row` for its copy menu, as a right-click does (`rightClick()`).
    pub fn right_click(&mut self, row: El) -> Result<(), String> {
        let p = self.invoke(row, "mapToItem", json!([null, 10, 10]))?;
        self.invoke(row, "menuRequested", json!([p["x"], p["y"]])).map(|_| ())
    }

    /// The y of `o` in the panel's coordinates.
    pub fn y_in_panel(&mut self, o: El) -> Result<f64, String> {
        let p = self.invoke(o, "mapToItem", json!([{ "target": "pop.panel" }, 0, 0]))?;
        p["y"].as_f64().ok_or_else(|| format!("mapToItem answered {p}"))
    }

    /// The texts under `o` drawn through a markup-parsing element: those
    /// with a `textFormat` other than `Text.PlainText`, and how many texts
    /// there are (`everyTextIsPlain()`, `:464-476`).
    pub fn markup_texts(&self, o: El) -> Result<(usize, Vec<String>), String> {
        let plain = self.get("Text", "PlainText")?;
        let mut count = 0;
        let mut bad = Vec::new();
        for c in std::iter::once(o).chain(self.find(o, None)?) {
            let (Ok(Value::String(text)), Ok(format)) = (self.get(c, "text"), self.get(c, "textFormat")) else {
                continue;
            };
            count += 1;
            if format != plain {
                bad.push(text);
            }
        }
        Ok((count, bad))
    }

    /// Records `id`: every text under `o` is plain, and there is one.
    pub fn check_plain(&mut self, id: &str, o: El) -> Result<(), String> {
        let (count, bad) = self.markup_texts(o)?;
        self.check(id, count > 0 && bad.is_empty(), json!({ "texts": count, "markup": bad }));
        Ok(())
    }

    /// The visible glyph (`tint`) under `o`, if it has one.
    pub fn glyph_shown(&self, o: El) -> Result<bool, String> {
        for c in self.find(o, None)? {
            if self.get(c, "tint").is_ok_and(|t| t.is_string()) {
                return self.flag(c, "visible");
            }
        }
        Ok(false)
    }
}

/// The one element of `els`, or an error naming `what`.
fn one(els: Vec<El>, what: &str) -> Result<El, String> {
    match els.as_slice() {
        [o] => Ok(*o),
        _ => Err(format!("expected one {what}, found {}", els.len())),
    }
}
