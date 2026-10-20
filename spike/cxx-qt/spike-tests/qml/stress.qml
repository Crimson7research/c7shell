// Check 4a, one "reload" cycle: start work on the tokio runtime, then let the
// test destroy the engine while callbacks are still in flight.
import QtQuick
import C7Spike

Window {
    width: 120; height: 120; visible: true
    PeerModel { id: peers }
    ListView { anchors.fill: parent; model: peers; delegate: Text { required property string name; text: name } }

    Connections {
        target: Spike
        // Exit on the first delivered callback; the other lines are still queued.
        function onCounterChanged() { if (Spike.counter === 1) Qt.exit(0) }
    }

    Component.onCompleted: {
        Spike.attach(peers);
        for (let i = 0; i < 50; i++)
            Spike.feed(i % 2 ? "a=1,b=0,c=1" : "a=0,c=1,d=1");
    }
}
