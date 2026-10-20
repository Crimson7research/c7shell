// Drives the round-2 contract checks. Each step feeds one snapshot line to
// Contract (which hands it to its backend: tokio or fake), waits until the
// singleton has applied it (revisionChanged, emitted last), then runs the
// step's checks. Exits with the number of failed checks. No timers, no sleeps.
import QtQml
import C7Spike

QtObject {
    id: runner
    property int failures: 0
    property int index: 0
    property var steps: []

    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    function start() { next(); }

    function next() {
        if (index >= steps.length) {
            Qt.exit(failures);
            return;
        }
        const line = steps[index].feed;
        if (!Contract.feed(line)) {
            check(false, "Contract.feed(" + line + ") returned true");
            Qt.exit(failures);
        }
    }

    property Connections watch: Connections {
        target: Contract
        function onRevisionChanged() {
            const s = runner.steps[runner.index];
            console.warn("-- step " + runner.index + ": " + s.feed);
            s.verify(runner);
            runner.index++;
            runner.next();
        }
    }
}
