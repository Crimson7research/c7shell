// Check 6: the C++ #286 module C7 loads into the Rust test binary's engine,
// and its Tailscale contract singleton is readable and callable.
// TS_SOCKET points at a path nothing listens on (set by the Rust side, the
// same isolation #286's own C7_TEST_MAIN applies), so no real tailscaled is
// reached and nothing can block on it.
import QtQml
import C7

QtObject {
    id: root
    property int failures: 0
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    // The action's outcome is published as state: a write to a socket that
    // does not exist is a Failed write, so writeError moves and writable
    // (true until a *refusal*) stays true.
    property Connections onWrite: Connections {
        target: Tailscale
        function onWriteErrorChanged() {
            root.check(Tailscale.writeError !== "", "writeError published after the failed write: \"" + Tailscale.writeError + "\"");
            root.check(Tailscale.writable === true, "writable stays true (a failed write is not a refusal)");
            root.check(Tailscale.state === Tailscale.NoState, "state still NoState after the write attempt");
            root.check(Tailscale.wantRunning === false, "the action did not publish the requested value");
            root.check(Tailscale.readError === "", "readError empty: nothing listening at TS_SOCKET (the no-tailscaled case)");
            Qt.exit(root.failures);
        }
    }

    Component.onCompleted: {
        check(typeof Tailscale === "object" && Tailscale !== null, "Tailscale singleton resolves from import C7");
        check(Tailscale.state === Tailscale.NoState && Tailscale.state === 0, "state starts NoState (" + Tailscale.state + ")");
        check(Tailscale.State.Running === 5, "State enum reachable: Running == " + Tailscale.State.Running);
        check(Tailscale.exitNodeBlocked === false, "exitNodeBlocked false");
        check(Tailscale.issueCount === 0, "issueCount 0");
        check(Tailscale.peers !== null && Tailscale.peers.rowCount() === 0, "peers model present and empty");
        check(Tailscale.writable === true, "writable starts true");
        check(Tailscale.writeError === "", "writeError starts empty");
        check(typeof Tailscale.setWantRunning === "function", "setWantRunning is a Q_INVOKABLE");
        Tailscale.setWantRunning(true);
        check(true, "setWantRunning(true) returned without blocking");
    }
}
