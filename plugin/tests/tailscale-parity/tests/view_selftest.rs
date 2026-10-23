//! The view runner's own checks, on the stub views under `selftest/views`:
//! the import tree, the choice of views, every driver command and every
//! verdict. Each view test runs in a respawned child.

mod support;

use std::path::Path;

use serde_json::json;
use support::{check, error, finish, selftest, verdict, STUB_IMPLEMENTATIONS};
use tailscale_parity::child::{self, PrivateRoot};
use tailscale_parity::runner::{self, Outcome, Report};
use tailscale_parity::views::run::{self, ViewImplementation};
use tailscale_parity::views::{tree, Body, El, Views};

const BODIES: &[(&str, Body)] = &[("ops", ops), ("fails", fails), ("errs", errs), ("warns", warns)];

/// Every driver command, checked from inside a child.
fn ops(v: &mut Views) -> Result<(), String> {
    v.check("fresh-state", v.get("Tailscale", "state")? == json!(0), v.get("Tailscale", "state")?);
    v.set("Tailscale", "state", json!({ "enum": "Running" }))?;
    v.check("enum-set", v.get("Tailscale", "state")? == json!(5), v.get("Tailscale", "state")?);
    let state = v.find("pop", Some("ts-state"))?;
    v.check("find-one", state.len() == 1, json!(state.len()));
    v.check("same-handle", v.find("pop", Some("ts-state"))? == state, json!(null));
    v.check("text", v.text(state[0], "text")? == "connected", v.get(state[0], "text")?);
    let red = json!("#ff0000"); // palette-literal-ok: the stub's red, as the driver writes it
    v.check("colour", v.get(state[0], "color")? == red, v.get(state[0], "color")?);
    let slot = v.find("pill", Some("tailscale"))?;
    v.check("slot-shown", slot.len() == 1 && v.flag(slot[0], "visible")?, json!(slot.len()));
    let label = v.find("pill", Some("ts-label"))?;
    let all = v.find(slot[0], None)?;
    v.check("find-all", label.len() == 1 && all.contains(&label[0]), json!(all.len()));
    v.set("Tailscale", "exitNodeName", json!("a name long enough to widen the row"))?;
    let (row, text) = (v.number(slot[0], "implicitWidth")?, v.number(label[0], "implicitWidth")?);
    v.check("layout-barrier", row >= text && text > 0.0, json!({ "row": row, "label": text }));
    let row = v.find("pop", Some("ts-row"))?[0];
    v.invoke(row, "clicked", json!([]))?;
    let calls = v.calls()?;
    v.check("calls", calls == "setAcceptRoutes(true)", json!(calls));
    v.check("calls-taken", v.calls()?.is_empty(), json!(null));
    v.set("Tailscale", "keyExpiry", json!({ "date_from_now_ms": 86_400_000 }))?;
    let expiry = v.get("Tailscale", "keyExpiry")?;
    v.check("date", expiry["date"].is_string(), expiry);
    v.invoke("PopoverManager", "toggle", json!(["tailscale", { "target": "pop" }]))?;
    let anchor = v.object("PopoverManager", "anchorItem")?;
    v.check("target-arg", anchor.is_some() && anchor == v.object("pop.panel", "parent")?, json!(null));
    v.check("plain-text", v.get("Text", "PlainText")?.is_number(), v.get("Text", "PlainText")?);
    let now = v.now()?;
    v.set("Tailscale", "keyExpiry", json!({ "date_ms": 86_400_000 }))?;
    let at = v.get("Tailscale", "keyExpiry")?;
    v.check("date-ms", at == json!({ "date": "1970-01-02T00:00:00.000Z" }), at);
    v.check("now", now > 1.0e12 && v.now()? >= now, json!(now));
    v.watch("Tailscale", "stateChanged")?;
    v.set("Tailscale", "state", json!({ "enum": "Stopped" }))?;
    v.set("Tailscale", "state", json!({ "enum": "Running" }))?;
    v.check("fired", v.fired("Tailscale", "stateChanged")? == 2, json!(v.fired("Tailscale", "stateChanged")?));
    v.watch("Tailscale", "stateChanged")?;
    v.check("rewatch-resets", v.fired("Tailscale", "stateChanged")? == 0, json!(v.fired("Tailscale", "stateChanged")?));
    v.set("Tailscale", "state", json!({ "enum": "Stopped" }))?;
    v.check(
        "rewatch-counts-once",
        v.fired("Tailscale", "stateChanged")? == 1,
        json!(v.fired("Tailscale", "stateChanged")?),
    );
    let unwatched = v.fired("Tailscale", "issuesChanged").unwrap_err();
    v.check("unwatched", unwatched.contains("is not watched"), json!(unwatched));
    delegates(v)?;
    let input = v.find("pop", Some("ts-input"))?[0];
    v.invoke(input, "forceActiveFocus", json!([]))?;
    v.check("focus", v.focus()? == Some(input), json!(v.focus()?.map(|e| e.0)));
    let at = v.invoke(input, "mapToItem", json!([{ "target": "pop.panel" }, 0, 0]))?;
    v.check("point", at["y"].as_f64().is_some_and(|y| y > 0.0), at);
    let unknown = v.get("Nowhere", "x").unwrap_err();
    v.check("unknown-target", unknown.contains("no target named Nowhere"), json!(unknown));
    let stale = v.get(El(9999), "x").unwrap_err();
    v.check("unknown-handle", stale.contains("no handle"), json!(stale));
    let member = v.get("Tailscale", "noSuchMember").unwrap_err();
    v.check("unknown-member", member.contains("has no member noSuchMember"), json!(member));
    Ok(())
}

/// A delegate is one handle while its row moves, and a new one after a
/// clear and refill.
fn delegates(v: &mut Views) -> Result<(), String> {
    for id in ["a", "b"] {
        v.invoke("Tailscale.peers", "append", json!([{ "nodeId": id }]))?;
    }
    let rows = v.find("pop", Some("ts-peer"))?;
    v.check("delegates", rows.len() == 2, json!(rows.len()));
    let first = rows.first().copied().ok_or("no delegate")?;
    v.set(first, "copied", json!(true))?;
    v.invoke("Tailscale.peers", "move", json!([0, 1, 1]))?;
    v.check("kept-delegate", v.find("pop", Some("ts-peer"))?.contains(&first), json!(null));
    v.check("kept-state", v.flag(first, "copied")?, json!(false));
    v.invoke("Tailscale.peers", "clear", json!([]))?;
    v.invoke("Tailscale.peers", "append", json!([{ "nodeId": "a" }]))?;
    let rebuilt = v.find("pop", Some("ts-peer"))?;
    v.check("new-delegate", rebuilt.len() == 1 && !rebuilt.contains(&first), json!(rebuilt.len()));
    Ok(())
}

fn fails(v: &mut Views) -> Result<(), String> {
    v.check("first", false, json!("actual-1"));
    v.check("second", true, json!("never reported"));
    Ok(())
}

fn errs(_: &mut Views) -> Result<(), String> {
    Err("a lookup failed".into())
}

fn warns(v: &mut Views) -> Result<(), String> {
    v.set("pill", "armed", json!(true))
}

/// Copies the directory `from` to `to`.
fn copy(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let path = entry.unwrap().path();
        let dest = to.join(path.file_name().unwrap());
        if path.is_dir() {
            copy(&path, &dest);
        } else {
            std::fs::copy(&path, &dest).unwrap();
        }
    }
}

fn stub_views() -> ViewImplementation {
    ViewImplementation { name: "stub".into(), views: selftest("views") }
}

fn run_header(id: &str) -> Report {
    let path = selftest("views-tests").join(format!("{id}.json"));
    run::run_one(&stub_views(), STUB_IMPLEMENTATIONS, BODIES, &path, &[("C7_HARNESS_MAX_ITERATIONS", "20000")])
}

/// 1. The tree: the stand-ins, the view files, the icons and the palette.
fn the_tree(failures: &mut Vec<String>) {
    let root = PrivateRoot::new();
    let into = root.path().join("tree");
    let built = tree::build(&selftest("views"), &into);
    check(failures, built.is_ok(), &format!("the stub views build a tree: {built:?}"));
    let read = |p: &str| std::fs::read_to_string(into.join(p)).unwrap_or_default();
    let all = tree::VIEW_FILES.iter().all(|f| into.join("qs").join(f).is_file());
    check(failures, all, "every view file is copied under qs/");
    check(failures, into.join("C7/Tailscale.qml").is_file(), "the stand-ins are copied");
    let theme = read("qs/Theme/Theme.qml");
    let icons = format!("file://{}", selftest("views/Assets/icons").display());
    check(failures, theme.contains(&icons) && !theme.contains("@ICONS_DIR@"), "the theme names the views' icons");
    let store = read("qs/Theme/PaletteStore.qml");
    let ok = store.contains("whitesmoke") && store.contains("crimson") && !store.contains("_note");
    check(failures, ok, &format!("the PaletteStore holds the palette without its prose: {store}"));
    let missing = tree::palette_store(r#"{"defaults": {}}"#);
    check(failures, missing.as_ref().is_err_and(|e| e.contains("palette")), &format!("no palette: {missing:?}"));
    let bare = root.path().join("standins");
    copy(&tree::standins(), &bare);
    let theme = bare.join("qs/Theme/Theme.qml");
    let text = std::fs::read_to_string(&theme).unwrap();
    std::fs::write(&theme, text.replace("@ICONS_DIR@", "file:///nowhere")).unwrap();
    let lost = tree::build_from(&bare, &selftest("views"), &root.path().join("tree3"));
    let ok = lost.as_ref().is_err_and(|e| e.contains("@ICONS_DIR@"));
    check(failures, ok, &format!("a theme stand-in without the placeholder is an error: {lost:?}"));
    let empty = root.path().join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let none = tree::build(&empty, &root.path().join("tree2"));
    let ok = none.as_ref().is_err_and(|e| e.contains("Modules/Bar/StatusPill.qml"));
    check(failures, ok, &format!("a views directory without the files is an error naming one: {none:?}"));
}

/// 2. The views a run is against.
fn the_views(failures: &mut Vec<String>) {
    let dir = selftest("views");
    let dir = dir.to_str();
    let cases: [(Option<&str>, Option<&str>, &str); 4] = [
        (None, dir, "C7_IMPL is unset"),
        (Some("qml6"), dir, "`qml6` is not one of"),
        (Some("cpp-286"), None, "build-reference.sh --views"),
        (Some("cpp-286"), Some("/nonexistent"), "holds no Modules/Popovers/TailscalePopover.qml"),
    ];
    for (name, views, want) in cases {
        let got = ViewImplementation::from_vars(name, views);
        check(failures, got.as_ref().is_err_and(|e| e.contains(want)), &format!("{name:?} {views:?}: {got:?}"));
    }
    let got = ViewImplementation::from_vars(Some("cpp-286"), dir);
    check(failures, got.is_ok(), &format!("the stub views are views: {got:?}"));
}

/// 3. Every driver command works from a body.
fn the_commands(failures: &mut Vec<String>) {
    let r = run_header("ops");
    verdict(failures, &r, true, &["pass, as declared"], |o| matches!(o, Outcome::Pass));
}

/// 4. The verdicts. A failing check matches only its declared actual;
///    an error, a `.qml:` warning or an unknown body never matches.
fn the_verdicts(failures: &mut Vec<String>) {
    let failing = |o: &Outcome| matches!(o, Outcome::Fail(f) if f.len() == 1 && f[0].actual == json!("actual-1"));
    verdict(failures, &run_header("fails-as-declared"), true, &["fail as declared: first"], failing);
    verdict(failures, &run_header("fails-otherwise"), false, &["\"another\"", "\"actual-1\""], failing);
    verdict(failures, &run_header("declared-pass-fails"), false, &["declared pass, but failing"], failing);
    verdict(failures, &run_header("errs"), false, &["error: a lookup failed"], error("a lookup failed"));
    let warned = run_header("warns");
    verdict(failures, &warned, false, &["QML diagnostics", "StatusPill.qml:"], error("QML diagnostics"));
    let unknown = run_header("no-body");
    verdict(failures, &unknown, false, &["no harness function is named `no_such_body`"], error("body"));
    check(failures, !unknown.started, "a header naming no body starts no child");
}

/// 5. Any log line naming a `.qml` file turns an outcome into an error.
fn the_diagnostics_rule(failures: &mut Vec<String>) {
    let kept = run::with_diagnostics(Outcome::Pass, "qml: a console line\nok");
    check(failures, kept == Outcome::Pass, &format!("a log without .qml: keeps the outcome: {kept:?}"));
    let log = "file:///t/A.qml:3: TypeError: x\nfile:///t/B.qml:9: ReferenceError: y";
    let turned = run::with_diagnostics(Outcome::Pass, log);
    let ok = matches!(&turned, Outcome::Error(e) if e.contains("A.qml:3") && e.contains("B.qml:9"));
    check(failures, ok, &format!("each .qml: line is named: {turned:?}"));
    let js = run::with_diagnostics(Outcome::Pass, "file:///t/DeviceType.js:2: ReferenceError: x");
    check(failures, matches!(js, Outcome::Error(_)), &format!("a .js: line is a diagnostic: {js:?}"));
    let result = format!("{}{{\"outcome\":\"error\",\"error\":\"/v/PeerRow.qml: missing\"}}", runner::RESULT_PREFIX);
    let kept = run::with_diagnostics(Outcome::Pass, &result);
    check(failures, kept == Outcome::Pass, &format!("the result line is no diagnostic: {kept:?}"));
}

/// 7. A result line after an exit that was not a success is an error.
fn the_exit_status(failures: &mut Vec<String>) {
    use std::os::unix::process::ExitStatusExt;
    let line = format!("{}{{\"outcome\":\"pass\"}}", runner::RESULT_PREFIX);
    let (ok, _) = run::parse_result(&line, std::process::ExitStatus::from_raw(0));
    check(failures, ok == Outcome::Pass, &format!("a pass and exit 0: {ok:?}"));
    let (crashed, _) = run::parse_result(&line, std::process::ExitStatus::from_raw(6));
    let ok = matches!(&crashed, Outcome::Error(e) if e.contains("after its result line"));
    check(failures, ok, &format!("a pass and a signal 6: {crashed:?}"));
}

/// 8. The host's logging settings cannot hide a warning.
fn the_logging_settings(failures: &mut Vec<String>) {
    // SAFETY: the self-test's main thread, with no other thread running.
    unsafe {
        std::env::set_var("QT_LOGGING_RULES", "*.warning=false;qml.warning=false");
        std::env::set_var("QT_MESSAGE_PATTERN", "%{type}");
    }
    let warned = run_header("warns");
    unsafe {
        std::env::remove_var("QT_LOGGING_RULES");
        std::env::remove_var("QT_MESSAGE_PATTERN");
    }
    verdict(failures, &warned, false, &["QML diagnostics", "StatusPill.qml:"], error("QML diagnostics"));
}

/// 6. run_all: a filter naming no header is an error, and the summary.
fn the_run_all(failures: &mut Vec<String>) {
    let dir = selftest("views-tests");
    let missing = run::run_all(&stub_views(), STUB_IMPLEMENTATIONS, BODIES, &dir, 1, Some("nothing-here"));
    let ok = missing.as_ref().is_err_and(|e| e.contains("no view test has the id nothing-here"));
    check(failures, ok, &format!("a filter matching nothing: {missing:?}"));
    let empty = run::run_all(&stub_views(), STUB_IMPLEMENTATIONS, BODIES, Path::new("/nonexistent"), 1, None);
    let twice = run::run_all(&stub_views(), STUB_IMPLEMENTATIONS, BODIES, &dir, 2, Some("ops"));
    let want = run::Summary { count: 1, implementation: "stub".into(), repeat: 2 };
    check(failures, twice.as_ref() == Ok(&want), &format!("two runs of ops: {twice:?}"));
    check(failures, empty.as_ref().is_err_and(|e| e.contains("no view tests found")), &format!("{empty:?}"));
    let summary = run::Summary { count: 3, implementation: "cpp-286".into(), repeat: 50 };
    let text = summary.to_string();
    check(failures, text == "3 view tests matched their declarations on cpp-286 in 50 runs", &text);
}

fn main() {
    if child::child_arg().as_deref() == Some("view") {
        std::process::exit(run::child_main(BODIES));
    }
    let mut failures = Vec::new();
    the_tree(&mut failures);
    the_views(&mut failures);
    the_commands(&mut failures);
    the_verdicts(&mut failures);
    the_diagnostics_rule(&mut failures);
    the_run_all(&mut failures);
    the_exit_status(&mut failures);
    the_logging_settings(&mut failures);
    std::process::exit(finish("view_selftest", &failures));
}
