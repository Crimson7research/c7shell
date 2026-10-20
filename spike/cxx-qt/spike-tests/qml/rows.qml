// Check 2: a reset-free update keeps the row (and the delegate) for "a".
// Updates arrive through the real path: Spike.feed -> Unix socket -> tokio
// task -> CxxQtThread::queue -> PeerModel diff on the Qt thread.
import QtQuick
import C7Spike

Window {
    id: win
    width: 200; height: 200; visible: true

    property int failures: 0
    property int resets: 0
    property var log: []
    property int destroyedA: 0
    property Item aItem: null
    property Item bItem: null

    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    PeerModel { id: peers }

    Connections {
        target: peers
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
        model: peers
        delegate: Rectangle {
            required property string name
            required property bool online
            width: 100; height: 20
            color: online ? "green" : "grey"
            Text { text: parent.name }
            Component.onDestruction: if (name === "a") win.destroyedA++
        }
    }

    function step(expectLog, what) {
        view.forceLayout();
        check(JSON.stringify(log) === JSON.stringify(expectLog),
              what + ": signals " + JSON.stringify(log) + " == " + JSON.stringify(expectLog));
        check(resets === 0, what + ": no modelReset / modelAboutToBeReset");
        log = [];
    }

    Connections {
        target: Spike
        function onCounterChanged() {
            switch (Spike.counter) {
            case 1:
                win.step(["ins:0-0"], "initial a");
                win.aItem = view.itemAtIndex(0);
                win.check(win.aItem !== null && win.aItem.name === "a", "delegate for a exists");
                Spike.feed("a=1,b=0");
                break;
            case 2:
                win.step(["ins:1-1"], "keep a, add b");
                win.check(view.count === 2, "view has 2 rows");
                win.check(view.itemAtIndex(0) === win.aItem, "row 0 delegate is the same object as before");
                win.check(win.destroyedA === 0, "delegate for a was never destroyed");
                win.check(peers.index(0, 0).row === 0, "model index for a still row 0");
                win.bItem = view.itemAtIndex(1);
                Spike.feed("a=0,b=0");
                break;
            case 3:
                win.step(["chg:0-0"], "change a in place");
                win.check(view.itemAtIndex(0) === win.aItem, "a delegate survives dataChanged");
                win.check(win.aItem.online === false, "a delegate sees online=false");
                Spike.feed("b=0");
                break;
            case 4:
                win.step(["rem:0-0"], "remove a, keep b");
                win.check(view.count === 1, "view has 1 row");
                win.check(view.itemAtIndex(0) === win.bItem, "b delegate survives removal of a");
                Qt.exit(win.failures);
                break;
            }
        }
    }

    // Start only once the window is exposed and has rendered: before that the
    // ListView may not have created delegates yet (seen 1/119 runs).
    property bool started: false
    onFrameSwapped: {
        if (started) return;
        started = true;
        Spike.attach(peers);
        Spike.feed("a=1");
    }
}
