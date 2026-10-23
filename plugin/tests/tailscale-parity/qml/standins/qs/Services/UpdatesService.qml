// At rest, so its slot stays out of the way.
pragma Singleton
import QtQuick

QtObject {
    property int total: 0
    property bool running: false
    property var pacnews: []
    property bool kernelPending: false
    property int runTotal: 0
    property int doneCount: 0
}
