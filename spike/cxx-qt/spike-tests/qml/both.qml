// Check 6 (second half): one engine imports the Rust C7Spike module and the
// C++ #286 C7 module together and drives a singleton from each.
import QtQml
import C7
import C7Spike

QtObject {
    id: root
    property int failures: 0
    property bool spikeDone: false
    property bool c7Done: false
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }
    function maybeExit() { if (spikeDone && c7Done) Qt.exit(failures); }

    property Connections onSpike: Connections {
        target: Spike
        function onCounterChanged() {
            root.check(Spike.state === "a=1,b=0", "C7Spike (Rust) tokio path works next to C7: " + Spike.state);
            root.spikeDone = true; root.maybeExit();
        }
    }
    property Connections onTs: Connections {
        target: Tailscale
        function onWriteErrorChanged() {
            root.check(Tailscale.writeError !== "", "C7 (C++) action outcome arrives next to C7Spike");
            root.c7Done = true; root.maybeExit();
        }
    }
    property PeerModel rustModel: PeerModel {}

    Component.onCompleted: {
        check(Spike.counter === 0 && Spike.state === "idle", "Spike singleton from C7Spike");
        check(Tailscale.state === Tailscale.NoState, "Tailscale singleton from C7");
        rustModel.applyText("a=1,b=1");
        check(rustModel.rowCount() === 2, "Rust PeerModel rows: " + rustModel.rowCount());
        check(Tailscale.peers.rowCount() === 0, "C++ peers model rows: 0");
        check(Spike.feed("a=1,b=0") === true, "Spike.feed()");
        Tailscale.setAcceptDns(true);
    }
}
