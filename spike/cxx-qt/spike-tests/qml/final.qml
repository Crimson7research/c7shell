// Check 4a, after all reload cycles: a fresh engine reads the process-wide
// counters kept by the (still loaded) plugin library.
import QtQml
import C7Spike

QtObject {
    property int failures: 0
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }
    Component.onCompleted: {
        const attempted = Spike.attemptedCallbacks(), ran = Spike.ranCallbacks(), dropped = Spike.droppedCallbacks();
        const refused = Spike.refusedCallbacks();
        console.warn("attempted " + attempted + " ran " + ran + " dropped-unrun " + dropped
                     + " (of which refused by queue() " + refused + ") late " + Spike.lateCallbacks());
        check(Spike.lateCallbacks() === 0, "no callback ran after its singleton was destroyed");
        check(Spike.liveRuntimes() === 1, "only this engine's runtime is alive: " + Spike.liveRuntimes());
        check(attempted === ran + dropped, "every callback either ran or was dropped unrun (none leaked)");
        check(dropped - refused > 0, "some posted callbacks were discarded at destruction (the race was exercised)");
        check(Spike.counter === 0, "the new engine got a fresh singleton");
        Qt.exit(failures);
    }
}
