// The stub bar pill: a slot named "tailscale" holding one label, and a
// binding that warns once `armed` is set, for the `.qml:` rule.
import QtQuick
import C7

Item {
    id: pill

    property bool armed: false
    property var nothing: null
    readonly property int broken: pill.armed ? pill.nothing.length : 0

    width: 200
    height: 26

    Row {
        objectName: "tailscale"
        visible: Tailscale.state !== Tailscale.NoState

        Text {
            objectName: "ts-label"
            text: Tailscale.exitNodeName
        }
    }
}
