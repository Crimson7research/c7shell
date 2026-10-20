// Check 5: a real Qt Quick scene (Window + ListView over PeerModel) renders
// frames under QT_QPA_PLATFORM=offscreen.
import QtQuick
import C7Spike

Window {
    id: win
    width: 160; height: 120; visible: true
    property int frames: 0
    property int failures: 0
    function check(ok, what) {
        console.warn((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    PeerModel { id: peers }
    ListView {
        id: view
        anchors.fill: parent
        model: peers
        delegate: Text { required property string name; text: name }
    }

    onFrameSwapped: {
        frames++;
        if (frames === 1) {
            peers.applyText("a=1,b=1,c=0");   // forces a second, different frame
        } else if (frames === 2) {
            check(Qt.platform.pluginName === "offscreen", "QPA platform is " + Qt.platform.pluginName);
            check(GraphicsInfo.api !== GraphicsInfo.Unknown, "scene graph API " + GraphicsInfo.api
                  + " (shaderType " + GraphicsInfo.shaderType + ")");
            check(view.count === 3, "ListView has 3 delegates-worth of rows: " + view.count);
            check(view.itemAtIndex(2) !== null && view.itemAtIndex(2).text === "c", "delegate for c rendered");
            Qt.exit(failures);
        }
    }
}
