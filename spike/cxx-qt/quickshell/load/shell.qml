// Check 1b (human, needs Quickshell): Quickshell loads the Cargo-built C7Spike
// module from QML_IMPORT_PATH and the singleton works.
//   QML_IMPORT_PATH=$PWD/target/qml qs -p quickshell/load/shell.qml
// PASS line:  C7SPIKE 1b PASS counter=1 state=a=1,b=0 rows=2
import QtQuick
import Quickshell
import C7Spike

ShellRoot {
    PeerModel { id: peers }

    Connections {
        target: Spike
        function onCounterChanged() {
            const ok = Spike.counter === 1 && Spike.state === "a=1,b=0" && peers.rowCount() === 2;
            console.log("C7SPIKE 1b " + (ok ? "PASS" : "FAIL") + " counter=" + Spike.counter
                        + " state=" + Spike.state + " rows=" + peers.rowCount());
            Qt.quit();
        }
    }

    Component.onCompleted: {
        console.log("C7SPIKE 1b loaded, state=" + Spike.state);
        Spike.attach(peers);
        Spike.feed("a=1,b=0");
    }
}
