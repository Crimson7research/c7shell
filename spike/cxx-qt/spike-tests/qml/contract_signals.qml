// Check 7e: two properties sharing ONE notify signal (issues and issueCount on
// issuesChanged), and a signal the contract derives from two inputs
// (exitNodeBlockedChanged off exitNodeActiveChanged and exitNodeOnlineChanged).
import QtQml
import C7Spike

QtObject {
    id: root
    property int issuesSignals: 0
    property int blockedSignals: 0
    property var blockedSeen: []   // exitNodeBlocked as read inside each blockedChanged
    // Both bindings depend only on issuesChanged.
    readonly property int boundCount: Contract.issueCount
    readonly property string boundIssues: Contract.issues.join("|")
    readonly property bool boundBlocked: Contract.exitNodeBlocked

    property Connections watch: Connections {
        target: Contract
        function onIssuesChanged() { root.issuesSignals++ }
        function onExitNodeBlockedChanged() {
            root.blockedSignals++;
            root.blockedSeen.push(Contract.exitNodeBlocked);
        }
    }

    function reset() { issuesSignals = 0; blockedSignals = 0; blockedSeen = []; }

    property StepRunner run: StepRunner {
        steps: [
            { feed: "issues=a|b|c", verify: function (r) {
                r.check(root.issuesSignals === 1, "one issuesChanged for one update: " + root.issuesSignals);
                r.check(Contract.issueCount === 3, "issueCount === 3");
                r.check(root.boundCount === 3, "binding on issueCount updated on issuesChanged");
                r.check(root.boundIssues === "a|b|c", "binding on issues updated on the same signal");
                root.reset();
            } },
            { feed: "issues=a", verify: function (r) {
                r.check(root.issuesSignals === 1 && root.boundCount === 1 && root.boundIssues === "a",
                        "both bindings follow a shrink: count " + root.boundCount + " issues " + root.boundIssues);
                root.reset();
            } },
            { feed: "active=1;online=1", verify: function (r) {
                r.check(!Contract.exitNodeBlocked && !root.boundBlocked, "active + online: not blocked");
                r.check(root.blockedSignals === 2, "blockedChanged fired once per input that moved: " + root.blockedSignals);
                root.reset();
            } },
            { feed: "online=0", verify: function (r) {
                r.check(Contract.exitNodeBlocked && root.boundBlocked, "active + offline: blocked (binding updated)");
                r.check(root.blockedSignals === 1, "one blockedChanged off exitNodeOnlineChanged");
                r.check(JSON.stringify(root.blockedSeen) === "[true]", "the new value was stored before the signal: " + JSON.stringify(root.blockedSeen));
                root.reset();
            } },
            { feed: "active=0", verify: function (r) {
                r.check(!Contract.exitNodeBlocked && !root.boundBlocked, "inactive: not blocked (binding updated)");
                r.check(root.blockedSignals === 1, "one blockedChanged off exitNodeActiveChanged");
                r.check(JSON.stringify(root.blockedSeen) === "[false]", "the new value was stored before the signal");
                root.reset();
            } },
            { feed: "issues=a;active=0", verify: function (r) {
                r.check(root.issuesSignals === 0 && root.blockedSignals === 0, "nothing moved, nothing fired");
            } },
        ]
    }

    Component.onCompleted: {
        const r = run;
        r.check(typeof Contract.issueCountChanged === "undefined", "there is no issueCountChanged signal");
        r.check(typeof Contract.issuesChanged === "function", "issuesChanged is a signal");
        r.check(typeof Contract.exitNodeBlockedChanged === "function", "exitNodeBlockedChanged is a signal");
        r.check(Contract.issueCount === 0 && !Contract.exitNodeBlocked, "starts with no issues, not blocked");
        r.start();
    }
}
