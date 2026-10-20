// Check 7c: Contract.peers is a CONSTANT model property; the singleton creates
// and owns the model (nothing here creates or attaches one). A ListView bound
// to it keeps its rows and delegates through updates that arrive from tokio.
import QtQuick
import C7Spike

Window {
    id: win
    width: 200; height: 200; visible: true

    property int resets: 0
    property var log: []
    property int destroyedA: 0
    property Item aItem: null
    property Item bItem: null

    Connections {
        target: Contract.peers
        function onModelAboutToBeReset() { win.resets++ }
        function onModelReset() { win.resets++ }
        function onRowsInserted(parent, first, last) { win.log.push("ins:" + first + "-" + last) }
        function onRowsRemoved(parent, first, last) { win.log.push("rem:" + first + "-" + last) }
        function onDataChanged(tl, br) { win.log.push("chg:" + tl.row + "-" + br.row) }
        function onLayoutChanged() { win.log.push("layout") }
        function onRowsMoved() { win.log.push("move") }
    }

    ListView {
        id: view
        anchors.fill: parent
        model: Contract.peers
        delegate: Rectangle {
            required property string name
            required property bool online
            width: 100; height: 20
            color: online ? "green" : "grey"
            Text { text: parent.name }
            Component.onDestruction: if (name === "a") win.destroyedA++
        }
    }

    ListView {
        id: exits
        model: Contract.exitNodes
        delegate: Text { required property string name; text: name }
    }

    function expectSignals(r, expected, what) {
        view.forceLayout();
        r.check(JSON.stringify(log) === JSON.stringify(expected),
                what + ": signals " + JSON.stringify(log) + " == " + JSON.stringify(expected));
        r.check(resets === 0, what + ": no modelReset / modelAboutToBeReset");
        log = [];
    }

    StepRunner {
        id: run
        steps: [
            { feed: "state=Running;peers=a=1", verify: function (r) {
                win.expectSignals(r, ["ins:0-0"], "initial a");
                win.aItem = view.itemAtIndex(0);
                r.check(win.aItem !== null && win.aItem.name === "a", "delegate for a exists");
            } },
            { feed: "peers=a=1,b=0", verify: function (r) {
                win.expectSignals(r, ["ins:1-1"], "keep a, add b");
                r.check(view.count === 2, "view has 2 rows");
                r.check(view.itemAtIndex(0) === win.aItem, "row 0 delegate is the same object as before");
                r.check(win.destroyedA === 0, "delegate for a was never destroyed");
                win.bItem = view.itemAtIndex(1);
                gc(); // the engine must not collect a model it does not own
                r.check(view.model === Contract.peers && Contract.peers.rowCount() === 2, "model survives gc()");
            } },
            { feed: "peers=a=0,b=0;exits=x=1", verify: function (r) {
                win.expectSignals(r, ["chg:0-0"], "change a in place");
                r.check(view.itemAtIndex(0) === win.aItem, "a delegate survives dataChanged");
                r.check(win.aItem.online === false, "a delegate sees online=false");
                r.check(exits.count === 1, "exitNodes (the second owned model) got its row");
            } },
            { feed: "peers=b=0", verify: function (r) {
                win.expectSignals(r, ["rem:0-0"], "remove a, keep b");
                r.check(view.count === 1, "view has 1 row");
                r.check(view.itemAtIndex(0) === win.bItem, "b delegate survives removal of a");
            } },
        ]
    }

    property bool started: false
    onFrameSwapped: {
        if (started) return;
        started = true;
        const r = run;
        r.check(Contract.peers !== null && Contract.exitNodes !== null, "both model properties are non-null");
        r.check(Contract.peers !== Contract.exitNodes, "two distinct models");
        r.check(Contract.peers === Contract.peers, "the property returns the same object on every read");
        r.check(typeof Contract.peersChanged === "undefined", "peers is CONSTANT (no peersChanged)");
        r.check(Contract.modelsParentedToSelf(), "both models' QObject parent is the singleton");
        r.check(Contract.peers.rowCount() === 0, "starts empty");
        r.check(Contract.backendThreads() === 1, "updates come from the tokio backend thread");
        r.start();
    }
}
