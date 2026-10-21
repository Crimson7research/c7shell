// The generic driver (plan decision P7). It hard-codes no member of
// Tailscale: it counts every *Changed signal it finds, and each model
// member's own signals as "<member>.<signal>", and runs each command
// Rust emits on Probe against Tailscale by name, answering through
// Probe.reply before the emit returns.
//
// Commands, as JSON: {"op": "read", "name"}, {"op": "enum", "key"},
// {"op": "call", "name", "args"}, {"op": "count", "name"}, {"op": "counts"}
// (every counted signal's count, by name), {"op": "members"},
// and on a model member {"op": "rows", "name", "row"},
// {"op": "has_children", "name", "row"} and {"op": "data", "name", "row",
// "role"} (row null for the root; role a name or "#<number>").
// The answer is {"value": ...} or {"error": "..."}.
import QtQml
import QtQml.Models
import C7
import C7Harness

QtObject {
    id: root

    // Signal name -> times fired since the driver loaded.
    property var counts: ({})

    // Model member name -> a DelegateModel over it. QAbstractItemModel's
    // roleNames() is not invokable from QML, so a role named in a scenario
    // is read the way a view reads it: through the delegate model's item
    // for the row, whose properties are the model's roles.
    property var views: ({})
    property Component viewOf: Component {
        DelegateModel {
            delegate: QtObject {}
        }
    }
    // The signals of a model member that are counted, as "<member>.<signal>".
    readonly property var modelSignals: ["rowsInserted", "rowsRemoved", "rowsMoved", "modelReset", "dataChanged", "layoutChanged"]

    // What a delegate model item has beside the model's roles.
    readonly property var notRoles: ["index", "row", "column", "model", "hasModelChildren", "modelData"]

    // A contract value as JSON: an enum is already a number, a Date is
    // {"date": ISO or null}, a model is {"rows": n}, a list is an array.
    function encode(v) {
        if (v === undefined)
            return { "undefined": true };
        if (v === null)
            return null;
        if (v instanceof Date)
            return { "date": isNaN(v.getTime()) ? null : v.toISOString() };
        if (typeof v === "object" && typeof v.rowCount === "function")
            return { "rows": v.rowCount() };
        if (typeof v === "object" && typeof v.length === "number") {
            const out = [];
            for (let i = 0; i < v.length; ++i)
                out.push(encode(v[i]));
            return out;
        }
        if (typeof v === "object")
            return String(v);
        return v;
    }

    function count(name, s) {
        root.counts[name] = 0;
        s.connect(function () { root.counts[name] += 1; });
    }

    function isModel(v) {
        return v !== null && typeof v === "object" && typeof v.rowCount === "function";
    }

    function member(name) {
        if (!(name in Tailscale))
            throw new Error("Tailscale has no member " + name);
        return Tailscale[name];
    }

    function model(name) {
        const m = member(name);
        if (!isModel(m))
            throw new Error(name + " is not a model");
        return m;
    }

    // Row `row` of model `name`'s role `role`, read by number through
    // data(), or by name through the delegate model.
    function data(name, row, role) {
        const m = model(name);
        if (role.startsWith("#"))
            return encode(m.data(m.index(row, 0), Number(role.slice(1))));
        if (!(name in root.views))
            root.views[name] = root.viewOf.createObject(root, { "model": m });
        const items = root.views[name].items;
        if (row >= items.count)
            throw new Error(name + " has no row " + row + " to read " + role + " from");
        const item = items.get(row).model;
        if (root.notRoles.includes(role) || !(role in item))
            throw new Error(role + " is not a role of " + name);
        return encode(item[role]);
    }

    function run(c) {
        switch (c.op) {
        case "read": {
            const v = member(c.name);
            if (typeof v === "function")
                throw new Error(c.name + " is a function, not a property");
            return encode(v);
        }
        case "enum": {
            const v = member(c.key);
            if (typeof v !== "number")
                throw new Error(c.key + " is not an enum value");
            return v;
        }
        case "call": {
            const f = member(c.name);
            if (typeof f !== "function")
                throw new Error(c.name + " is not callable");
            const r = f.apply(Tailscale, c.args || []);
            return r === undefined ? null : encode(r);
        }
        case "count":
            if (!(c.name in root.counts))
                throw new Error("no signal " + c.name + " is counted");
            return root.counts[c.name];
        case "counts":
            return Object.assign({}, root.counts);
        case "rows": {
            const m = model(c.name);
            return c.row === null ? m.rowCount() : m.rowCount(m.index(c.row, 0));
        }
        case "has_children": {
            const m = model(c.name);
            return c.row === null ? m.hasChildren() : m.hasChildren(m.index(c.row, 0));
        }
        case "data":
            return data(c.name, c.row, c.role);
        case "members": {
            const names = [];
            for (const k in Tailscale)
                names.push(k);
            return names.sort();
        }
        default:
            throw new Error("unknown op " + c.op);
        }
    }

    property Connections probe: Connections {
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

    // An exception here (a C7 without Tailscale, say) is reported through
    // Probe.failed, so the load ends at once and says why. So is a Tailscale
    // that is no backend object: null (a create() that returned nullptr) or
    // a type name with no instance, which list no members, and through
    // which a scenario that reads only the fake would pass.
    Component.onCompleted: {
        try {
            let members = 0;
            for (const k in Tailscale) {
                members += 1;
                const s = Tailscale[k];
                if (k.endsWith("Changed") && s && typeof s.connect === "function")
                    root.count(k, s);
                // A model member is read once, here: #286's are CONSTANT,
                // so the object counted is the one every read returns.
                if (isModel(s)) {
                    for (const sig of root.modelSignals)
                        root.count(k + "." + sig, s[sig]);
                }
            }
            if (Tailscale === null || typeof Tailscale !== "object" || members === 0) {
                Probe.failed("Tailscale is no backend object: " + String(Tailscale) + " has no members");
                return;
            }
        } catch (e) {
            Probe.failed(String(e));
            return;
        }
        Probe.ready();
    }
}
