// Loaded in a second engine, with only the module directory on its import
// path (R-UI-01). It exits with 3 when Tailscale is no object, 4 when it
// is the first engine's (it carries the name the driver gave that one)
// and 5 when it is another object.
import QtQml
import C7

QtObject {
    Component.onCompleted: {
        if (Tailscale === null || typeof Tailscale !== "object")
            Qt.exit(3);
        else
            Qt.exit(Tailscale.objectName === "c7-harness-first-engine" ? 4 : 5);
    }
}
