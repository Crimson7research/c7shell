// The popover frame without its window: a column of the content, open
// while PopoverManager names it.
import QtQuick
import qs.Services

Item {
    id: root
    required property string name
    property int padding: 14
    property int gap: 11
    property int panelWidth: 320
    property bool pinRight: false
    default property alias content: column.data
    readonly property alias panel: panel
    property bool open: PopoverManager.current === root.name

    width: panel.width
    height: panel.height

    Item {
        id: panel
        width: root.panelWidth
        height: column.implicitHeight + root.padding * 2

        Column {
            id: column
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                margins: root.padding
            }
            spacing: root.gap
        }
    }
}
