// Check 7f: the same QML runs against whichever backend the singleton chose at
// construction (C7SPIKE_CONTRACT_BACKEND, read in Default). The test passes
// --expect-backend=<name> so this file can assert which one it got.
import QtQml
import C7Spike

QtObject {
    id: root
    readonly property string expected:
        (Qt.application.arguments.find(a => a.startsWith("--expect-backend=")) || "=").split("=")[1]

    property StepRunner run: StepRunner {
        steps: [
            { feed: "state=Running;issues=x;peers=a=1,b=1", verify: function (r) {
                r.check(Contract.state === Contract.Running, "state Running");
                r.check(Contract.issueCount === 1, "issueCount 1");
                r.check(Contract.peers.rowCount() === 2, "peers has 2 rows");
            } },
            { feed: "active=1;online=0", verify: function (r) {
                r.check(Contract.exitNodeBlocked, "exitNodeBlocked derived the same way under this backend");
            } },
        ]
    }

    Component.onCompleted: {
        const r = run;
        console.warn("C7SPIKE 7f backend=" + Contract.backend + " expected=" + expected);
        r.check(expected === "tokio" || expected === "fake", "the test said which backend to expect: " + expected);
        r.check(Contract.backend === expected, "Contract.backend === " + expected + ": " + Contract.backend);
        const threads = expected === "tokio" ? 1 : 0;
        r.check(Contract.backendThreads() === threads, "backend threads === " + threads + ": " + Contract.backendThreads());
        r.start();
    }
}
