pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import qs.Theme
import qs.Common

// Turn 14: the 280px panel, and the only place a password is asked for.
//
// One component, every caller. The design's four states and four per-caller
// variants are not eight layouts -- the order is fixed (icon, what, who is
// asking, field, actions) and a caller may replace the icon, the two text
// lines and the button labels. Nothing else. So everything below is driven by
// the request the daemon sent and the stage the conversation is in; there is
// no per-caller branch that draws its own thing.
//
// Bound properties rather than AuthService directly, so the panel can be
// stood up in a test with no daemon behind it.
Item {
  id: root

  // The daemon's request object: kind, title, detail, actionId, command,
  // proc, pid, user, group, root.
  required property var request
  property string stage: "ask"          // ask · verifying · wrong
  // The reader is listening. Not a stage: the field stays live beside it.
  property bool fingerprint: false
  property int tries: 0
  property int maxTries: 3
  property bool promptReady: true
  property string promptText: ""
  property string noticeText: ""
  property string pamError: ""
  property int factorMisses: 0
  property int waiting: 0

  signal submitted(string secret)
  signal cancelled

  readonly property string kind: root.request?.kind ?? "polkit"
  // Colour carries the privilege level and nothing else: crimson tile means
  // root, neutral tile means the secret is scoped to one app or one network.
  readonly property bool privileged: root.request?.root === true
  // The compact variant (38px tile and field) is for the prompts that are not
  // asking for the account password of the person at the keyboard.
  readonly property bool compact: root.kind !== "polkit"

  readonly property bool verifying: root.stage === "verifying"
  readonly property bool failed: root.stage === "wrong"
  readonly property bool onFactor: root.fingerprint

  // -- the replaceable surface ----------------------------------------------
  // The design lets a caller replace the icon, the two text lines and the
  // button labels, and nothing else. Those five are computed here rather than
  // inline in the views below, so that surface is one readable list -- and so
  // a test can check every state without reaching into a nested Text.

  readonly property string headline: root.verifying ? "Checking…"
      : root.failed && root.kind === "polkit" ? "Authentication failed"
      : (root.request?.title ?? "Authentication required")

  // Ranked by what the person most needs to read. A PAM error outranks
  // everything; a PAM notice ("the account is locked due to 3 failed logins")
  // outranks the caller's own description, because it is the only line that
  // explains why the password that works is not working.
  readonly property string description: root.pamError !== "" ? root.pamError
      : root.noticeText !== "" ? root.noticeText
      : root.kind === "sudo" ? root.askedBy
      : (root.request?.detail ?? "")

  readonly property string iconName: root.failed ? "alert-triangle"
      : root.onFactor ? "fingerprint"
      : root.kind === "sudo" ? "terminal"
      : root.kind === "keyring" ? "key"
      : root.kind === "wifi" ? "wifi"
      : "lock"

  readonly property string cancelLabel: root.kind === "keyring" ? "deny" : "cancel"

  readonly property string primaryLabel: root.failed ? "try again"
      : root.kind === "sudo" ? "run"
      : root.kind === "wifi" ? "connect"
      : root.kind === "keyring" ? "unlock"
      : "authenticate"

  readonly property string fieldPlaceholder: root.kind === "wifi" ? "network key"
      : root.kind === "keyring" ? "keyring password"
      // PAM's own wording, when it asked for something that is not the
      // password: at that point the only honest label is the one it wrote.
      : root.promptText !== "" && root.promptText.toLowerCase() !== "password:"
        ? root.promptText.replace(/:$/, "")
        : root.onFactor ? "password, or touch the sensor"
        : "password"

  // "asked by foot · pid 41207": the terminal, not the shell it was typed
  // into. Naming the window in front of the person is the point.
  readonly property string askedBy: {
    const proc = root.request?.proc ?? ""
    const pid = root.request?.pid ?? 0
    if (proc === "" && !pid) return ""
    return pid ? `asked by ${proc || "an unknown process"} · pid ${pid}` : `asked by ${proc}`
  }

  // A finger the reader did not match: the print shakes, the way a wrong
  // password shakes the panel.
  onFactorMissesChanged: if (root.factorMisses > 0) glyph.reject()

  function focusInput() { field.focusInput() }
  function clearInput() { field.clear() }

  implicitWidth: 280
  implicitHeight: panel.height

  GlassPanel {
    id: panel
    width: parent.width
    height: column.implicitHeight + (root.compact ? 32 : 36)
    radius: root.compact ? 18 : 20
    // The panel border is the failure indicator that survives the shake: the
    // field can be typed back into a clean state, the frame should not be.
    border.color: root.failed ? Theme.alpha(Theme.accent, 0.40) : Theme.hairlineStrong

    // Swallows clicks so a stray press inside the panel is not read as the
    // dismiss the backdrop offers.
    MouseArea { anchors.fill: parent }

    Column {
      id: column
      anchors {
        left: parent.left; right: parent.right
        top: parent.top
        leftMargin: root.compact ? 16 : 18
        rightMargin: root.compact ? 16 : 18
        topMargin: root.compact ? 16 : 20
      }
      spacing: 0

      // -- the print ---------------------------------------------------------
      // While the reader is listening the print replaces the tile. The field
      // stays below it, live: c7-authd runs the password beside the reader,
      // so typing never waits for the finger to time out.
      FingerprintGlyph {
        id: glyph
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.onFactor
        size: 64
        // The whole print, coloured, with the beam sweeping it while the
        // reader listens -- not the sheet's empty one, which is a print still
        // being recorded.
        fill: 1
        litColor: root.privileged ? Theme.accent : Theme.alpha(Theme.text, 0.8)
        scanning: root.onFactor
      }

      // -- icon tile ---------------------------------------------------------
      Rectangle {
        id: tile
        visible: !root.onFactor
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.compact ? 38 : 44
        height: width
        radius: root.compact ? 12 : 14
        color: root.privileged
             ? Theme.alpha(Theme.accent, root.failed ? 0.16 : 0.14)
             : Theme.alpha(Theme.text, 0.06)
        border.width: 1
        border.color: root.privileged
                    ? Theme.alpha(Theme.accent, root.failed ? 0.40 : 0.30)
                    : Theme.alpha(Theme.text, 0.09)

        // The one thing that moves while verifying.
        Spinner {
          anchors.centerIn: parent
          visible: root.verifying
          size: root.compact ? 17 : 19
          arcColor: Theme.alpha(Theme.accent, 0.85)
        }

        Icon {
          anchors.centerIn: parent
          visible: !root.verifying
          size: root.compact ? 17 : 19
          tint: root.privileged ? Theme.accentSoft : Theme.alpha(Theme.text, 0.65)
          name: root.iconName
        }
      }

      Item { width: 1; height: root.compact ? 11 : 13 }

      // -- what ---------------------------------------------------------------
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        // Never "administrator privileges": the caller's own words, and only
        // the conversation's own stage overrides them.
        text: root.headline
        font { family: Theme.fontMono; pixelSize: root.compact ? 12 : 12; weight: 600 }
        color: Theme.text
        elide: Text.ElideRight
      }

      // -- the command, when there is one to show -----------------------------
      // sudo only. A polkit prompt names its action instead: pkexec's own
      // command line is already in the message polkit wrote.
      Item { width: 1; height: 6; visible: cmdBlock.visible }

      Rectangle {
        id: cmdBlock
        width: parent.width
        height: 28
        visible: root.kind === "sudo" && (root.request?.command ?? "") !== ""
        radius: 9
        color: Qt.rgba(0, 0, 0, 0.4)
        border.width: 1
        border.color: Theme.surface07

        Text {
          anchors {
            left: parent.left; right: parent.right
            leftMargin: 9; rightMargin: 9
            verticalCenter: parent.verticalCenter
          }
          text: root.request?.command ?? ""
          font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
          color: Theme.alpha(Theme.text, 0.72)
          elide: Text.ElideRight
        }
      }

      // -- who is asking ------------------------------------------------------
      Item { width: 1; height: 5 }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        // The alternate factor replaces the description with what PAM is
        // actually waiting for; an error PAM raised outranks both.
        text: root.description
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        lineHeight: 1.5
        color: root.pamError !== "" ? Theme.accentSoft : Theme.alpha(Theme.text, 0.45)
      }

      // The action id, kept visible rather than hidden: it is the only part of
      // a polkit prompt that can be checked against anything.
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        visible: (root.request?.actionId ?? "") !== ""
        text: root.request?.actionId ?? ""
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.alpha(Theme.text, 0.32)
        elide: Text.ElideMiddle
      }

      // -- who is authenticating ----------------------------------------------
      Item { width: 1; height: 13; visible: identity.visible }

      Rectangle {
        id: identity
        width: parent.width
        height: 40
        visible: root.kind === "polkit" && (root.request?.user ?? "") !== ""
        radius: 11
        color: Theme.surface04
        border.width: 1
        border.color: Theme.hairline
        // Dimmed, not hidden, while verifying: the row is context, and context
        // that disappears mid-prompt is one more thing to re-read.
        opacity: root.verifying ? 0.5 : 1

        Rectangle {
          id: avatar
          anchors { left: parent.left; leftMargin: 11; verticalCenter: parent.verticalCenter }
          width: 22; height: 22; radius: 11
          color: Theme.alpha(Theme.accent, 0.18)
          border.width: 1
          border.color: Theme.alpha(Theme.accent, 0.32)

          // The same avatar the greeter shows. AccountsService keeps it under
          // the login name, which is where a directory backend drops the photo
          // it fetched; a local account that never set one simply has no file
          // and keeps its initials. Only the name polkit resolved is used, and
          // only if it looks like a login name -- the path must not be able to
          // point outside that directory.
          readonly property string user: root.request?.user ?? ""
          readonly property url picture: /^[a-z0-9._-]+$/.test(avatar.user)
                                         ? "file:///var/lib/AccountsService/icons/" + avatar.user
                                         : ""
          readonly property bool hasPicture: avatar.picture != "" && face.status === Image.Ready

          Text {
            anchors.centerIn: parent
            visible: !avatar.hasPicture
            text: avatar.user.slice(0, 2).toUpperCase()
            font { family: Theme.fontMono; pixelSize: 8; weight: 600 }
            color: Theme.text
          }

          Image {
            id: face
            anchors.fill: parent
            source: avatar.picture
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: false
            sourceSize.width: 44
          }

          MultiEffect {
            anchors.fill: parent
            source: face
            visible: avatar.hasPicture
            maskEnabled: true
            maskSource: faceMask
          }

          Item {
            id: faceMask
            anchors.fill: parent
            layer.enabled: true
            visible: false
            Rectangle { anchors.fill: parent; radius: 11; color: "black" }
          }
        }

        // Name only. The mockup has a group chip beside it ("alex  wheel");
        // see user_name() in bin/c7-authd for why there is nothing truthful to
        // put there -- polkit resolves its identities to a user before the
        // agent sees them, so the group that made this user eligible is not
        // something we are told, and guessing one next to a password field
        // asserts a reason we cannot check.
        Text {
          anchors {
            left: avatar.right; leftMargin: 9
            right: parent.right; rightMargin: 11
            verticalCenter: parent.verticalCenter
          }
          text: root.request?.user ?? ""
          font { family: Theme.fontMono; pixelSize: 10; weight: 500 }
          color: Theme.alpha(Theme.text, 0.7)
          elide: Text.ElideRight
        }
      }

      // -- the field ----------------------------------------------------------
      Item { width: 1; height: 8 }

      SecretField {
        id: field
        width: parent.width
        compact: root.compact
        locked: root.verifying
        revealable: root.kind === "wifi"
        placeholder: root.fieldPlaceholder
        error: root.failed ? "wrong password" : ""
        counter: root.failed ? `${root.tries} of ${root.maxTries}` : ""

        onAccepted: secret => root.submitted(secret)
        onCancelled: root.cancelled()
      }

      // -- actions ------------------------------------------------------------
      Item { width: 1; height: 9 }

      Row {
        width: parent.width
        spacing: 7

        // Cancel stays live in every state, verifying included. A prompt you
        // cannot get out of is the thing people learn to fear.
        PromptButton {
          width: (parent.width - 7) / 2
          compact: root.compact
          label: root.cancelLabel
          onClicked: root.cancelled()
        }

        PromptButton {
          width: (parent.width - 7) / 2
          compact: root.compact
          primary: true
          label: root.primaryLabel
          dimmed: root.verifying
          onClicked: if (!root.verifying) root.submitted(field.text)
        }
      }
    }
  }
}
