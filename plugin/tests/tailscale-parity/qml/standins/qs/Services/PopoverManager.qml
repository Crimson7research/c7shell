// Records which popover is open and its anchor, which is all the slot asks.
pragma Singleton
import QtQuick

QtObject {
    property string current: ""
    property Item anchorItem: null
    function toggle(name, item) {
        current = name;
        anchorItem = item;
    }
}
