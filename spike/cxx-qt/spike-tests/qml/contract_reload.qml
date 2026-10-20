// Check 7c lifetime, one "reload" cycle: bind views to the singleton's owned
// models, push 50 snapshots through tokio, and let the test destroy the
// engine while the rest are still in flight. Creates no PeerModel itself.
import QtQuick
import C7Spike

Window {
    width: 120; height: 120; visible: true
    ListView { anchors.fill: parent; model: Contract.peers; delegate: Text { required property string name; text: name } }
    ListView { model: Contract.exitNodes; delegate: Text { required property string name; text: name } }

    Connections {
        target: Contract
        function onRevisionChanged() {
            if (Contract.revision !== 1) return;
            gc();
            Qt.exit(Contract.modelsParentedToSelf() && Contract.peers.rowCount() > 0 ? 0 : 1);
        }
    }

    Component.onCompleted: {
        for (let i = 0; i < 50; i++)
            Contract.feed(i % 2 ? "peers=a=1,b=0,c=1;exits=a=1" : "peers=a=0,c=1,d=1;exits=c=1");
    }
}
