// Holds its content and never shows: no tooltip text is under test here.
import QtQuick

Item {
    id: root
    property bool open: false
    property Item anchorItem: null
    property int panelWidth: 200
    property real panelHeight: 0
    property int panelRadius: 9
    default property alias content: card.data

    visible: false

    Item {
        id: card
        width: root.panelWidth
        height: root.panelHeight
    }
}
