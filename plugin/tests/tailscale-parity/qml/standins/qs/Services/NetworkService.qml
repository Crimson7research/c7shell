// At rest, so its slot stays out of the way.
pragma Singleton
import QtQuick

QtObject {
    property string primary: "wifi"
    property var ethDevice: null
}
