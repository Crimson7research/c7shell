// The stub popover: a state line, a row whose click records a call, a
// text input and a list of peers whose delegates keep local state.
import QtQuick
import C7

Item {
    id: pop

    readonly property alias panel: panel

    width: 320
    height: panel.height

    Column {
        id: panel

        width: 320

        Text {
            objectName: "ts-state"
            text: Tailscale.state === Tailscale.Running ? "connected" : "no daemon"
            color: "red"
        }

        Item {
            objectName: "ts-row"
            width: 10
            height: 10
            signal clicked
            onClicked: Tailscale.setAcceptRoutes(!Tailscale.acceptRoutes)
        }

        TextInput {
            objectName: "ts-input"
            width: 50
            height: 10
        }

        ListView {
            objectName: "ts-list"
            width: 100
            height: 100
            model: Tailscale.peers
            delegate: Item {
                required property string nodeId
                property bool copied: false
                objectName: "ts-peer"
                width: 10
                height: 10
            }
        }
    }
}
