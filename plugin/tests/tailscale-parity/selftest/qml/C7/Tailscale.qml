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

    function setAcceptRoutes(on) {
        acceptRoutes = on;
        writeError = "set " + on;
    }

    function setIssues(list) {
        issues = list;
    }

    // Asks the application to exit, as a crash before a result would end it.
    function quit(code) {
        Qt.exit(code);
    }
}
