// Check 7a: the Rust type ContractObject is a QML singleton named `Contract`
// (QML_NAMED_ELEMENT), and the Rust type name is not what QML sees.
import QtQml
import C7Spike

QtObject {
    id: root

    // A second, independently created object reads the singleton too: it must
    // be the same instance.
    property Component other: Component { QtObject { property var c: Contract } }

    property StepRunner run: StepRunner {
        steps: [
            { feed: "state=Running", verify: function (r) {
                r.check(Contract.state === Contract.Running, "the singleton applied a snapshot (state Running)");
                r.check(Contract.revision === 1, "revision 1 after the first snapshot");
            } },
        ]
    }

    Component.onCompleted: {
        const r = run;
        r.check(typeof Contract === "object" && Contract !== null, "`Contract` resolves to an object");
        r.check(typeof ContractObject === "undefined", "the Rust type name `ContractObject` is not a QML name");
        r.check(String(Contract).indexOf("ContractObject") === 0, "the C++ class behind it is ContractObject: " + String(Contract));
        const o = other.createObject(root);
        r.check(o.c === Contract, "a second object sees the same singleton instance");
        o.destroy();
        r.check(Contract.backend === "tokio", "default backend is the real (tokio) one: " + Contract.backend);
        r.check(Contract.revision === 0, "revision starts at 0");
        r.start();
    }
}
