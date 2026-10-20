// Check 4b (human, needs Quickshell): 20 real Quickshell reloads in one qs
// process; every generation gets a fresh Spike singleton (and tokio runtime),
// and the old generation's runtime must be gone.
//   QML_IMPORT_PATH=$PWD/target/qml qs -p quickshell/reload/shell.qml
// One "C7SPIKE 4b gen" line per generation, then a final PASS/FAIL line.
import QtQuick
import Quickshell
import C7Spike

ShellRoot {
    PeerModel { id: peers }

    Connections {
        target: Spike
        function onCounterChanged() { settle.start() }
    }

    // Give Quickshell time to destroy the previous generation. This is a
    // manual procedure, not a test, so a wall-clock settle is acceptable here.
    Timer {
        id: settle
        interval: 500
        onTriggered: {
            const gen = Spike.createdRuntimes();
            console.log("C7SPIKE 4b gen=" + gen + " live=" + Spike.liveRuntimes()
                        + " tokioThreads=" + Spike.tokioThreads() + " threads=" + Spike.threadCount()
                        + " late=" + Spike.lateCallbacks());
            if (gen < 21) {
                Quickshell.reload(false);
                return;
            }
            const ok = Spike.liveRuntimes() === 1 && Spike.tokioThreads() === 1 && Spike.lateCallbacks() === 0;
            console.log("C7SPIKE 4b " + (ok ? "PASS" : "FAIL") + " after " + (gen - 1) + " reloads");
            Qt.quit();
        }
    }

    Component.onCompleted: {
        Spike.attach(peers);
        Spike.feed("a=1,b=0");
    }
}
