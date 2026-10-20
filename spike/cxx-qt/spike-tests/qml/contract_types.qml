// Check 7d: QDateTime and QStringList property types with NOTIFY, read in QML
// as a JS Date and a JS array.
import QtQml
import C7Spike

QtObject {
    id: root
    property int expirySignals: 0
    property int issuesSignals: 0
    // Bindings must re-evaluate on the NOTIFY signals.
    readonly property real boundExpiry: Contract.keyExpiry.getTime()
    readonly property int boundLength: Contract.issues.length

    property Connections watch: Connections {
        target: Contract
        function onKeyExpiryChanged() { root.expirySignals++ }
        function onIssuesChanged() { root.issuesSignals++ }
    }

    property StepRunner run: StepRunner {
        steps: [
            { feed: "expiry=1767225600000", verify: function (r) {
                const d = Contract.keyExpiry;
                r.check(d instanceof Date, "keyExpiry is a JS Date");
                r.check(d.getTime() === 1767225600000, "keyExpiry.getTime() === 1767225600000: " + d.getTime());
                r.check(d.toISOString() === "2026-01-01T00:00:00.000Z", "keyExpiry is 2026-01-01T00:00:00Z: " + d.toISOString());
                r.check(root.boundExpiry === 1767225600000, "binding on keyExpiry re-evaluated");
                r.check(root.expirySignals === 1, "keyExpiryChanged fired once");
                root.expirySignals = 0;
            } },
            { feed: "issues=dns broken|key expiring soon", verify: function (r) {
                const l = Contract.issues;
                r.check(l.length === 2, "issues.length === 2: " + l.length);
                r.check(l[0] === "dns broken" && l[1] === "key expiring soon", "issues[0], issues[1]: " + JSON.stringify(l));
                r.check(l.join("|") === "dns broken|key expiring soon", "join works on the list");
                r.check(l.indexOf("key expiring soon") === 1, "indexOf works on the list");
                r.check(root.boundLength === 2, "binding on issues.length re-evaluated");
                r.check(root.issuesSignals === 1, "issuesChanged fired once");
                r.check(root.expirySignals === 0, "keyExpiryChanged did not fire for an issues-only snapshot");
                root.issuesSignals = 0;
            } },
            { feed: "expiry=none;issues=", verify: function (r) {
                r.check(isNaN(Contract.keyExpiry.getTime()), "a cleared expiry reads as an invalid Date");
                r.check(Contract.issues.length === 0, "cleared issues read as an empty array");
                r.check(root.expirySignals === 1 && root.issuesSignals === 1, "both signals fired once");
            } },
        ]
    }

    Component.onCompleted: {
        const r = run;
        r.check(Contract.keyExpiry instanceof Date, "keyExpiry starts as a Date");
        r.check(isNaN(Contract.keyExpiry.getTime()), "an invalid QDateTime reads as an invalid Date (NaN)");
        r.check(Contract.issues.length === 0, "issues starts empty");
        r.start();
    }
}
