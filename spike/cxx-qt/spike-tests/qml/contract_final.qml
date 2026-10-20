// Check 7c lifetime, after all reload cycles: a fresh engine reads the
// process-wide PeerModel counters kept by the (still loaded) plugin library.
import QtQml
import C7Spike

QtObject {
    property int failures: 0
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }
    Component.onCompleted: {
        const created = Contract.createdModels(), live = Contract.liveModels();
        const expected = Number(Qt.application.arguments.find(a => a.startsWith("--expect-created="))?.split("=")[1]);
        console.warn("PeerModels created " + created + " live " + live + " expected created " + expected);
        check(created === expected, "every singleton created exactly its 2 models: " + created + " === " + expected);
        check(live === 2, "only this singleton's 2 models are alive (each earlier one destroyed exactly once): " + live);
        check(Contract.revision === 0, "the new engine got a fresh singleton");
        check(Contract.modelsParentedToSelf(), "the new singleton owns its models");
        Qt.exit(failures);
    }
}
