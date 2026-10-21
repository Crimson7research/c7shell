// A QML-only stand-in for C7.Tailscale, used only to test the harness
// without #286. It does no I/O.
pragma Singleton
import QtQml

QtObject {
    enum State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running }

    property int state: 0
    property string writeError: ""
    property bool acceptRoutes: false
    property list<string> issues: []
    // Two models, as #286's peers and exitNodes are. ListModel numbers its
    // roles from 0; exitNodes has one, so its role 0 is hostName.
    property ListModel peers: ListModel {
        ListElement { hostName: "alpha"; nodeId: "n1"; online: true }
        ListElement { hostName: "bravo"; nodeId: "n2"; online: false }
        ListElement { hostName: "charlie"; nodeId: "n3"; online: true }
    }
    property ListModel exitNodes: ListModel {
        ListElement { hostName: "bravo" }
    }

    function setAcceptRoutes(on) {
        acceptRoutes = on;
        writeError = "set " + on;
    }

    function setIssues(list) {
        issues = list;
    }

    function addPeer(hostName, nodeId) {
        peers.append({ "hostName": hostName, "nodeId": nodeId, "online": true });
    }

    function removePeer(row) {
        peers.remove(row);
    }

    function movePeer(from, to) {
        peers.move(from, to, 1);
    }

    function setOnline(row, on) {
        peers.setProperty(row, "online", on);
    }

    // ListModel has no call that resets or re-lays itself out, so these
    // emit the model's own signals, as a model's endResetModel() and
    // layoutChanged() would. They change no rows.
    function resetPeers() {
        peers.modelReset();
    }

    function relayoutPeers() {
        peers.layoutChanged();
    }

    // Asks the application to exit, as a crash before a result would end it.
    function quit(code) {
        Qt.exit(code);
    }
}
