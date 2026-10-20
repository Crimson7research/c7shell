// Check 7b: a Q_ENUM declared on the singleton, used as a property type with
// NOTIFY: readable as Contract.Running and comparable to Contract.state.
import QtQml
import C7Spike

QtObject {
    id: root
    property int stateSignals: 0
    // A binding on the enum property must re-evaluate on stateChanged.
    readonly property bool running: Contract.state === Contract.Running

    property Connections watch: Connections {
        target: Contract
        function onStateChanged() { root.stateSignals++ }
    }

    property StepRunner run: StepRunner {
        steps: [
            { feed: "state=Running", verify: function (r) {
                r.check(Contract.state === Contract.Running, "state === Contract.Running");
                r.check(root.running, "binding on state === Contract.Running re-evaluated to true");
                r.check(root.stateSignals === 1, "stateChanged fired once: " + root.stateSignals);
                root.stateSignals = 0;
            } },
            { feed: "state=Stopped", verify: function (r) {
                r.check(Contract.state === Contract.Stopped, "state === Contract.Stopped");
                r.check(Contract.state !== Contract.Running, "state !== Contract.Running");
                r.check(!root.running, "binding re-evaluated to false");
                r.check(root.stateSignals === 1, "stateChanged fired once: " + root.stateSignals);
                root.stateSignals = 0;
            } },
            { feed: "state=Stopped;active=1", verify: function (r) {
                r.check(root.stateSignals === 0, "no stateChanged when the state did not move");
            } },
            { feed: "state=NoState", verify: function (r) {
                r.check(Contract.state === Contract.NoState, "back to NoState");
                r.check(root.stateSignals === 1, "stateChanged fired once");
            } },
        ]
    }

    Component.onCompleted: {
        const r = run;
        r.check(Contract.state === Contract.NoState, "state starts as Contract.NoState");
        const names = ["NoState", "NeedsMachineAuth", "NeedsLogin", "Stopped", "Starting", "Running"];
        for (let i = 0; i < names.length; i++)
            r.check(Contract[names[i]] === i, "Contract." + names[i] + " === " + i);
        r.check(Contract.State.Running === Contract.Running, "scoped form Contract.State.Running also works");
        r.check(typeof Contract.state === "number", "the property reads as a number in JS");
        r.start();
    }
}
