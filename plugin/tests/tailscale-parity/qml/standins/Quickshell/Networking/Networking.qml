// No network devices: the other slots stay hidden.
pragma Singleton
import QtQuick

QtObject {
    readonly property var devices: ({ values: [] })
}
