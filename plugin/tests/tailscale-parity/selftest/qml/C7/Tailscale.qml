// A QML-only stand-in for C7.Tailscale, used only to test the harness
// without #286. It does no I/O.
pragma Singleton
import QtQml

QtObject {
    enum State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running }

    property int state: 0
    property string writeError: ""
    property bool acceptRoutes: false

    function setAcceptRoutes(on) {
        acceptRoutes = on;
        writeError = "set " + on;
    }
}
