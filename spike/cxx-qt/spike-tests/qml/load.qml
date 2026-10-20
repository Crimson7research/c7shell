// Check 1a: `import C7Spike` resolves from the import path and the singleton works.
import QtQml
import C7Spike

QtObject {
    id: root
    property int failures: 0
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    property Connections onCounter: Connections {
        target: Spike
        function onCounterChanged() {
            root.check(Spike.counter === 1, "counter property NOTIFY fired, counter == 1");
            root.check(Spike.state === "hello=1", "state property updated from the tokio task: " + Spike.state);
            Qt.exit(root.failures);
        }
    }

    Component.onCompleted: {
        check(Spike.state === "idle", "singleton read-only property state starts idle");
        check(Spike.counter === 0, "singleton counter starts at 0");
        check(Spike.feed("hello=1") === true, "Q_INVOKABLE feed() returned true");
    }
}
