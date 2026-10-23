// The view driver (#309, plan decision V4): #286's bar pill and Tailscale
// popover in a window, over the QML stand-in, answering each command Rust
// emits on Probe through Probe.reply before the emit returns. It knows no
// `ts-` name: Rust finds elements by objectName and reads them by name.
//
// An object crosses to Rust as {"handle": n}, numbered by identity, so the
// same object is always the same handle. A target is a handle or a name:
// Tailscale, Quickshell, PopoverManager, Theme, pop, pill, window, Text or
// Qt, then member names joined by dots ("Tailscale.peers", "pop.panel").
//
// Commands, as JSON: {"op": "get", "target", "name"}, {"op": "set",
// "target", "name", "value"}, {"op": "invoke", "target", "name", "args"},
// {"op": "find", "target", "name"} (the target's descendants, through
// children and contentItem, whose objectName is `name`, or all when it is
// null), {"op": "layout"} (the layout barrier: five forceLayout() passes
// over the popover's and the pill's descendants), {"op": "calls"} (the
// stand-in's recorded calls since the last, taken), {"op": "focus"} (the
// window's active focus item), {"op": "now"} (Date.now()), and
// {"op": "watch", "target", "signal"} then {"op": "fired", "target",
// "signal"} (how often that signal has fired since it was watched). A value
// or argument {"handle": n} is that object, {"target": t} the object `t`
// names, {"enum": key} Tailscale's enum value `key`, {"date_ms": n} the
// Date at n ms since the epoch and {"date_from_now_ms": n} a Date n ms from
// now. The answer is {"value": ...} or {"error": "..."}.
import QtQuick
import QtQuick.Window
import Quickshell
import C7
import qs.Theme
import qs.Modules.Bar
import qs.Modules.Popovers
import qs.Services
import C7Harness

Window {
    id: root

    visible: true
    width: 480
    height: 900

    StatusPill {
        id: pill
    }

    TailscalePopover {
        id: pop
    }

    // Objects handed to Rust, by handle.
    property var handles: []

    // The stand-in's calls since the last `calls`.
    property var calls: []

    // "<handle>.<signal>" -> times fired since `watch`.
    property var fired: ({})

    Connections {
        target: Tailscale
        function onCalled(call) {
            root.calls.push(call);
        }
    }

    function handle(o) {
        let n = root.handles.indexOf(o);
        if (n < 0) {
            n = root.handles.length;
            root.handles.push(o);
        }
        return { "handle": n };
    }

    function isObject(v) {
        return v !== null && typeof v === "object" && typeof v.objectName === "string";
    }

    function isColor(v) {
        return v !== null && typeof v === "object" && v.hslHue !== undefined && v.a !== undefined;
    }

    function isPoint(v) {
        return v !== null && typeof v === "object" && typeof v.x === "number" && typeof v.y === "number";
    }

    // A value as JSON: an object as its handle, a colour as `${c}`, a Date
    // as {"date": ISO or null}, a point as {"x", "y"}.
    function encode(v) {
        if (v === undefined)
            return { "undefined": true };
        if (v === null || typeof v !== "object")
            return v;
        if (v instanceof Date)
            return { "date": isNaN(v.getTime()) ? null : v.toISOString() };
        if (isObject(v))
            return handle(v);
        if (isColor(v))
            return String(v);
        if (isPoint(v))
            return { "x": v.x, "y": v.y };
        if (typeof v.length === "number") {
            const out = [];
            for (let i = 0; i < v.length; ++i)
                out.push(encode(v[i]));
            return out;
        }
        const out = {};
        for (const k in v)
            out[k] = encode(v[k]);
        return out;
    }

    function named(name) {
        switch (name) {
        case "Tailscale":
            return Tailscale;
        case "Quickshell":
            return Quickshell;
        case "PopoverManager":
            return PopoverManager;
        case "Theme":
            return Theme;
        case "pop":
            return pop;
        case "pill":
            return pill;
        case "window":
            return root;
        case "Text":
            return Text;
        case "Qt":
            return Qt;
        }
        throw new Error("no target named " + name);
    }

    function resolve(t) {
        if (t !== null && typeof t === "object") {
            if (!(t.handle >= 0 && t.handle < root.handles.length))
                throw new Error("no handle " + JSON.stringify(t));
            return root.handles[t.handle];
        }
        const parts = String(t).split(".");
        let o = named(parts[0]);
        for (const p of parts.slice(1)) {
            if (o === null || o === undefined || !(p in o))
                throw new Error(t + " has no member " + p);
            o = o[p];
        }
        return o;
    }

    function decode(v) {
        if (v === null || typeof v !== "object")
            return v;
        if (Array.isArray(v))
            return v.map(decode);
        if ("handle" in v)
            return resolve(v);
        if ("target" in v)
            return resolve(v.target);
        if ("enum" in v) {
            const n = Tailscale[v["enum"]];
            if (typeof n !== "number")
                throw new Error(v["enum"] + " is not an enum value of Tailscale");
            return n;
        }
        if ("date_ms" in v)
            return new Date(v.date_ms);
        if ("date_from_now_ms" in v)
            return new Date(Date.now() + v.date_from_now_ms);
        const out = {};
        for (const k in v)
            out[k] = decode(v[k]);
        return out;
    }

    function member(o, name) {
        if (o === null || o === undefined || !(name in o))
            throw new Error(String(o) + " has no member " + name);
        return o[name];
    }

    function collect(item, seen) {
        if (!item)
            return seen;
        for (const c of (item.children ?? [])) {
            if (seen.indexOf(c) >= 0)
                continue;
            seen.push(c);
            root.collect(c, seen);
        }
        const inner = item.contentItem ?? null;
        if (inner && inner !== item && seen.indexOf(inner) < 0) {
            seen.push(inner);
            root.collect(inner, seen);
        }
        return seen;
    }

    function layout() {
        for (let pass = 0; pass < 5; ++pass) {
            for (const o of root.collect(pop, []).concat(root.collect(pill, [])))
                if (o.forceLayout !== undefined)
                    o.forceLayout();
        }
    }

    function run(c) {
        switch (c.op) {
        case "get":
            return encode(member(resolve(c.target), c.name));
        case "set":
            member(resolve(c.target), c.name);
            resolve(c.target)[c.name] = decode(c.value);
            return null;
        case "invoke": {
            const o = resolve(c.target);
            const f = member(o, c.name);
            if (typeof f !== "function")
                throw new Error(c.name + " is not callable");
            const r = f.apply(o, decode(c.args || []));
            return r === undefined ? null : encode(r);
        }
        case "find":
            return root.collect(resolve(c.target), []).filter(o => c.name === null || o.objectName === c.name).map(handle);
        case "layout":
            root.layout();
            return null;
        case "calls": {
            const taken = root.calls;
            root.calls = [];
            return taken;
        }
        case "focus":
            return encode(root.activeFocusItem);
        case "now":
            return Date.now();
        case "watch": {
            const o = resolve(c.target);
            const s = member(o, c.signal);
            const key = handle(o).handle + "." + c.signal;
            if (!(key in root.fired)) {
                root.fired[key] = 0;
                s.connect(function () {
                    root.fired[key] += 1;
                });
            }
            return null;
        }
        case "fired": {
            const key = handle(resolve(c.target)).handle + "." + c.signal;
            if (!(key in root.fired))
                throw new Error(c.signal + " is not watched");
            return root.fired[key];
        }
        default:
            throw new Error("unknown op " + c.op);
        }
    }

    Connections {
        target: Probe
        function onCommand(json) {
            let answer;
            try {
                answer = { "value": root.run(JSON.parse(json)) };
            } catch (e) {
                answer = { "error": String(e) };
            }
            Probe.reply(JSON.stringify(answer));
        }
    }

    Component.onCompleted: Probe.ready()
}
