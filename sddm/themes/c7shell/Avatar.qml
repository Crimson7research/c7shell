import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// The user's face when one was found, initials otherwise. sddm resolves the
// model's icon role from /usr/share/sddm/faces and from AccountsService, which
// is where a directory backend drops the photo it fetched. The crimson
// gradient disc is the shell's MonogramTile grown up to 76px, with the accent
// glow the mockup puts behind it.
Item {
  id: root

  property int size: Theme.avatarSize
  property string name: ""
  property string realName: ""
  property url picture: ""
  // The 30px variant in the user list: thinner ring, no glow, smaller type.
  property bool compact: false

  readonly property bool hasPicture: picture != "" && face.status === Image.Ready

  // "Alex Mertens" -> "AM", "alex" -> "AL", "" -> "?". realName is what sddm
  // read out of GECOS; the login name is the fallback.
  readonly property string initials: {
    const src = (root.realName !== "" ? root.realName : root.name).trim()
    if (src === "") return "?"
    const words = src.toLowerCase().split(/[\s._\-]+/).filter(w => w.length > 0)
    if (words.length === 0) return "?"
    if (words.length === 1) return words[0].slice(0, 2).toUpperCase()
    return (words[0].charAt(0) + words[1].charAt(0)).toUpperCase()
  }

  implicitWidth: root.size
  implicitHeight: root.size

  RectangularShadow {
    anchors.fill: parent
    radius: root.size / 2
    color: Theme.crimson(0.22)
    blur: Theme.px(34)
    spread: 0
    visible: !root.compact
    z: -1
  }

  // linear-gradient(150deg, crimson .34, crimson .08). Shapes rather than a
  // Rectangle gradient, which only runs on an axis.
  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: Theme.crimson(root.compact ? 0.40 : 0.35)
      strokeWidth: 1
      fillGradient: LinearGradient {
        x1: root.size * 0.75; y1: 0
        x2: root.size * 0.25; y2: root.size
        GradientStop { position: 0; color: Theme.crimson(root.compact ? 0.36 : 0.34) }
        GradientStop { position: 1; color: Theme.crimson(root.compact ? 0.10 : 0.08) }
      }
      PathAngleArc {
        centerX: root.size / 2; centerY: root.size / 2
        radiusX: root.size / 2 - 0.5; radiusY: root.size / 2 - 0.5
        startAngle: 0; sweepAngle: 360
      }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !root.hasPicture
    text: root.initials
    color: Theme.text
    font.family: root.compact ? Theme.fontMono : Theme.fontDisplay
    font.pixelSize: root.compact ? Theme.fs(10) : Theme.fs(24)
    font.weight: 600
  }

  Image {
    id: face
    anchors.fill: parent
    source: root.picture
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    visible: false
    sourceSize.width: root.size * 2
  }

  MultiEffect {
    anchors.fill: parent
    source: face
    visible: root.hasPicture
    maskEnabled: true
    maskSource: mask
  }

  Item {
    id: mask
    anchors.fill: parent
    layer.enabled: true
    visible: false
    Rectangle {
      anchors.fill: parent
      radius: root.size / 2
      color: "black"
    }
  }
}
