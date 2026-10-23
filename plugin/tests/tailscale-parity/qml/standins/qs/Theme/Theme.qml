// The theme stand-in (R-QML-27). The real Theme reads AppearanceStore,
// which needs Quickshell proper, so the views read this instead. Its
// colours come from the views' own palette.json, through the PaletteStore
// the harness generates beside it, so no token says something the shell
// does not. The harness replaces @ICONS_DIR@ with the views' icon folder.
pragma Singleton
import QtQuick
import qs.Theme

QtObject {
    id: root

    readonly property var palette: PaletteStore.palette
    readonly property var defaults: PaletteStore.defaults

    // A generic family: a missing font would print a warning.
    readonly property string fontMono: "monospace"

    readonly property color text: root.palette.text
    readonly property color text2: root.alpha(root.text, 0.55)
    readonly property color text3: root.alpha(root.text, 0.40)
    readonly property color textDisabled: root.alpha(root.text, 0.28)
    readonly property color textOnAccent: root.palette.textOnAccent
    readonly property color success: root.palette.success
    readonly property color warning: root.palette.warning

    readonly property color accent: root.defaults.accent
    readonly property color accentSoft: Qt.hsla(root.accent.hslHue, root.accent.hslSaturation * 0.90, Math.min(1, root.accent.hslLightness + 0.108), 1)
    readonly property color accentFill: root.alpha(root.accent, 0.14)
    readonly property color accentFillActive: root.alpha(root.accent, 0.16)
    readonly property color accentFillSoft: root.alpha(root.accent, 0.11)
    readonly property color accentBorder: root.alpha(root.accent, 0.30)
    readonly property color accentBorderSoft: root.alpha(root.accent, 0.22)
    readonly property color powerHover: root.alpha(root.accent, 0.28)

    readonly property color glassBase: root.palette.variants.dark.glassBase
    readonly property color bg: root.palette.variants.dark.bg
    readonly property color canvas: root.palette.variants.dark.canvas

    readonly property color surface04: Qt.rgba(1, 1, 1, 0.04)
    readonly property color surface05: Qt.rgba(1, 1, 1, 0.05)
    readonly property color surface07: Qt.rgba(1, 1, 1, 0.07)
    readonly property color surface10: Qt.rgba(1, 1, 1, 0.10)
    readonly property color hairline: Qt.rgba(1, 1, 1, 0.08)
    readonly property color hairlineStrong: Qt.rgba(1, 1, 1, 0.10)
    readonly property color hoverPill: Qt.rgba(1, 1, 1, 0.09)
    readonly property color wellFill: Qt.rgba(0, 0, 0, 0.28)
    readonly property color barShadowColor: Qt.rgba(0, 0, 0, 0.5)
    readonly property color panelShadowColor: Qt.rgba(0, 0, 0, 0.65)

    readonly property real glassAlphaBar: 0.78
    readonly property real glassAlphaPanel: 0.80

    readonly property int radiusPanel: 18
    readonly property int radiusRow: 12
    readonly property int radiusChip: 9
    readonly property int radiusCard: 14
    readonly property int radiusTile: 10
    readonly property int radiusPip: 7
    readonly property int radiusSlot: 8
    readonly property int radiusMenu: 13
    readonly property int radiusMenuRow: 8

    readonly property int pillHeight: 26
    readonly property int pillRadius: 13

    // The views' own icons, so an icon nobody drew is a warning here.
    readonly property url iconsDir: "@ICONS_DIR@"

    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
}
