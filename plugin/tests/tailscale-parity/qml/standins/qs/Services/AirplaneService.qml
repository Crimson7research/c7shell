// At rest, so its slot stays out of the way.
pragma Singleton
import QtQuick

QtObject {
    property bool enabled: false
    function setEnabled(v) {}
}
