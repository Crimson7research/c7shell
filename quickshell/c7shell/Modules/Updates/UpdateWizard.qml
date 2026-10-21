pragma ComponentBehavior: Bound
import Quickshell
import QtQuick
import qs.Theme
import qs.Common
import qs.Services

// 13a / 13b: the window the escalated path opens, and only the escalated path.
//
// The step counter is built from what the dry run found, so it is two dots or
// three, never a fixed three -- a step that cannot apply is not shown greyed
// out, it is not there. The three reduced entries are the same window with
// fewer steps:
//
//   approve  1 approve · 2 run · 3 clean up (3 only if predicted)
//   review   step 3 alone, no dots -- what the toast's "review now" opens
//   failure  step 2, stopped, proposing actions instead of asking a question
//
// A Loader around the window for the same reason SettingsWindow uses one:
// killing the toplevel destroys it, and assigning visible=true to the corpse
// does nothing.
Scope {
  id: root

  property string entry: "approve"
  property int step: 1

  readonly property bool hasCleanup:
    UpdatesService.pacnews.length > 0 || UpdatesService.rebootRequired
    || UpdatesService.services.length > 0 || UpdatesService.orphans.length > 0

  // Two dots or three. On the review-only entry there are none at all.
  readonly property int stepCount: {
    if (root.entry === "review") return 0
    return root.hasCleanup || UpdatesService.rebootPredicted ? 3 : 2
  }

  Connections {
    target: UpdatesService
    function onWizardRequested(entry) {
      root.entry = entry
      root.step = entry === "approve" ? 1 : entry === "review" ? 3 : 2
      frame.active = true
    }
    // Step 2 walks itself forward. Step 3 exists only if the run produced
    // something to clean up; otherwise the wizard closes itself and hands over
    // to the 12a toast, which is the whole reason the toast exists.
    function onFinished(ok) {
      if (!frame.active) return
      if (!ok) return                       // the failure view stays put
      if (root.hasCleanup) root.step = 3
      else frame.active = false
    }
  }

  Loader { id: frame; active: false; sourceComponent: windowComponent }

  Component {
    id: windowComponent

    FloatingWindow {
      id: win

      visible: true
      onVisibleChanged: if (!win.visible) frame.active = false
      title: "c7shell updates"
      color: Theme.canvas
      implicitWidth: 396
      implicitHeight: Math.min(680, body.implicitHeight + 44)
      minimumSize: Qt.size(396, 260)

      Column {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 22 }
        spacing: 14

        // -- title + step dots ---------------------------------------------------
        Item {
          width: parent.width
          height: heading.implicitHeight

          Column {
            id: heading
            width: parent.width - dots.width - 12
            spacing: 3

            Text {
              text: root.entry === "failure" ? `Stopped at package ${UpdatesService.result?.done ?? 0}`
                  : root.step === 1 ? "Before we update"
                  : root.step === 2 ? (UpdatesService.awaitingAuth ? "Waiting for authorisation" : "Updating")
                  : root.entry === "review"
                    ? (UpdatesService.pacnews.length > 0
                       ? `${UpdatesService.pacnews.length} config file${UpdatesService.pacnews.length === 1 ? "" : "s"} to review`
                       : `${UpdatesService.orphans.length} package${UpdatesService.orphans.length === 1 ? "" : "s"} nothing needs`)
                  : `Done — ${UpdatesService.result?.updated ?? 0} updated`
              font { family: Theme.fontDisplay; pixelSize: 13; weight: 700 }
              color: Theme.text
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              text: root.entry === "failure"
                  ? (UpdatesService.result?.failed === "pacman"
                     ? `${UpdatesService.result?.done ?? 0} installed · nothing left half-applied`
                     : `${UpdatesService.result?.done ?? 0} installed`)
                  : root.step === 1
                  ? `${UpdatesService.total} packages · ${UpdatesService.humanSize(UpdatesService.size)} · ${UpdatesService.total - UpdatesService.decisions.length} auto-approved`
                  : root.step === 2
                  ? (UpdatesService.awaitingAuth
                     ? "confirm the prompt to continue"
                     : `${UpdatesService.doneCount} of ${UpdatesService.runTotal}`)
                  : root.entry === "review"
                  ? "from an earlier update"
                  : `${UpdatesService.duration(UpdatesService.result?.secs)} · log at ${UpdatesService.logPath}`
              font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
              color: Theme.text3
            }
          }

          Row {
            id: dots
            anchors { right: parent.right; top: parent.top; topMargin: 3 }
            spacing: 5
            visible: root.stepCount > 0

            Repeater {
              model: root.stepCount

              Rectangle {
                required property int index
                width: 6; height: 6; radius: 3
                color: index + 1 === root.step ? Theme.accent
                     : index + 1 < root.step ? Theme.alpha(Theme.accent, 0.45)
                     : Theme.surface10
              }
            }
          }
        }

        // ================================================== step 1 · approve ====
        Column {
          width: parent.width
          spacing: 10
          visible: root.step === 1

          // The routine bumps, folded away. They are the overwhelming majority
          // and none of them is a question; putting them behind one line is
          // what leaves room to read the four that are.
          Item {
            width: parent.width
            height: 15

            Text {
              anchors.left: parent.left
              text: `${UpdatesService.total - UpdatesService.decisions.length} routine version bumps, already approved`
              font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
              color: Theme.text3
            }
            Text {
              id: showRoutine
              property bool open: false
              anchors.right: parent.right
              text: showRoutine.open ? "hide ▾" : "show ▸"
              font { family: Theme.fontMono; pixelSize: 10 }
              color: Theme.text3

              HoverHandler { cursorShape: Qt.PointingHandCursor }
              TapHandler { onTapped: showRoutine.open = !showRoutine.open }
            }
          }

          Column {
            width: parent.width
            spacing: 6
            visible: showRoutine.open

            Repeater {
              model: UpdatesService.sources
              SourceCard {
                required property var modelData
                width: parent.width
                source: modelData
                expanded: true
              }
            }
          }

          SectionLabel {
            text: `needs your ok · ${UpdatesService.decisions.length}`
            visible: UpdatesService.decisions.length > 0
          }

          Column {
            width: parent.width
            spacing: 6

            Repeater {
              model: UpdatesService.decisions

              Rectangle {
                id: decision
                required property var modelData
                readonly property bool skipped: UpdatesService.skipped.includes(decision.modelData.id)

                width: parent.width
                implicitHeight: dbody.implicitHeight + 18
                radius: Theme.radiusRow
                color: decision.skipped ? Theme.surface04 : Theme.accentFill
                border.width: 1
                border.color: decision.skipped ? Theme.hairline : Theme.accentBorder
                opacity: decision.skipped ? 0.6 : 1

                Row {
                  id: dbody
                  anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
                  spacing: 9

                  Rectangle {   // the tick
                    anchors.verticalCenter: parent.verticalCenter
                    width: 13; height: 13; radius: 4
                    color: decision.skipped ? "transparent" : Theme.accent
                    border.width: 1
                    border.color: decision.skipped ? Theme.hairlineStrong : Theme.accent

                    Text {
                      anchors.centerIn: parent
                      visible: !decision.skipped
                      text: "✓"
                      font { family: Theme.fontMono; pixelSize: 8; weight: 700 }
                      color: Theme.textOnAccent
                    }
                  }

                  Column {
                    width: parent.width - 22 - (diffLink.visible ? diffLink.width + 9 : 0)
                    spacing: 2

                    Row {
                      spacing: 6
                      Text {
                        text: decision.modelData.title
                        font { family: Theme.fontMono; pixelSize: 11; weight: 600 }
                        color: Theme.text
                      }
                      Text {
                        visible: (decision.modelData.detail ?? "") !== ""
                        text: decision.modelData.detail.split("\n")[0]
                        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
                        color: Theme.text2
                      }
                    }
                    Text {
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: decision.modelData.note ?? ""
                      font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
                      color: Theme.text3
                    }
                  }

                  Text {
                    id: diffLink
                    anchors.verticalCenter: parent.verticalCenter
                    visible: decision.modelData.diff === true
                    text: "view diff"
                    font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
                    color: Theme.accentSoft

                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                      onTapped: UpdatesService.showDiff(decision.modelData.title)
                    }
                  }
                }

                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  // Ticking is the whole interaction: unchecked items are
                  // skipped, not blocked, so nothing here can dead-end the run.
                  onTapped: UpdatesService.toggleSkip(decision.modelData.id)
                }
              }
            }
          }

          Text {
            text: "unchecked items are skipped, not blocked"
            font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
            color: Theme.textDisabled
          }
        }

        // ====================================================== step 2 · run ====
        RunView {
          width: parent.width
          visible: root.step === 2 && root.entry !== "failure"
          showPhases: true
          showHeadline: false
          logLines: 6
        }

        // ================================================== step 2 · failed ====
        Column {
          width: parent.width
          spacing: 10
          visible: root.entry === "failure"

          Rectangle {
            width: parent.width
            implicitHeight: err.implicitHeight + 18
            radius: Theme.radiusRow
            color: Theme.accentFill
            border.width: 1
            border.color: Theme.accentBorder

            Text {
              id: err
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
              wrapMode: Text.Wrap
              text: UpdatesService.result?.error ?? "the update stopped"
              font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
              color: Theme.text2
            }
          }

          // pacman rolls its transaction back. An AUR or flatpak phase runs
          // after the repo phase finished, and installs one package at a time.
          // A c7up that died before saying which phase failed promises neither.
          Text {
            text: UpdatesService.result?.failed === "pacman"
              ? "transaction rolled back — no files written"
              : UpdatesService.result?.failed
                ? "updates that finished before this stay installed"
                : "the update stopped before it finished"
            font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
            color: Theme.text3
          }

          SectionLabel { text: "what you can do" }

          Row {
            spacing: 7
            GhostButton { label: "retry"; onTriggered: { root.entry = "approve"; root.step = 1 } }
            GhostButton { label: "open in terminal"; onTriggered: UpdatesService.openInTerminal() }
            GhostButton {
              label: "copy error"
              onTriggered: Quickshell.clipboardText = UpdatesService.result?.error ?? ""
            }
          }

          Text {
            text: "step 3 is skipped — there is nothing to clean up"
            font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
            color: Theme.textDisabled
          }
        }

        // ================================================= step 3 · clean up ====
        Column {
          width: parent.width
          spacing: 10
          visible: root.step === 3 && root.entry !== "failure"

          SectionLabel {
            visible: UpdatesService.pacnews.length > 0
            text: `config files to review · ${UpdatesService.pacnews.length} pacnew`
          }

          Column {
            width: parent.width
            spacing: 7

            Repeater {
              model: UpdatesService.pacnews
              PacnewRow {
                required property var modelData
                width: parent.width
                file: modelData
              }
            }
          }

          Rectangle {
            width: parent.width
            visible: UpdatesService.services.length > 0
            implicitHeight: svc.implicitHeight + 18
            radius: Theme.radiusRow
            color: Theme.surface04
            border.width: 1
            border.color: Theme.hairline

            Column {
              id: svc
              anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
              spacing: 6

              Text {
                text: `${UpdatesService.services.length} service${UpdatesService.services.length === 1 ? "" : "s"} want a restart`
                font { family: Theme.fontMono; pixelSize: 11; weight: 500 }
                color: Theme.text
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: UpdatesService.services.join(" · ")
                font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
                color: Theme.text3
              }
              Row {
                spacing: 6
                GhostButton {
                  label: "restart them"
                  onTriggered: UpdatesService.restartServices(UpdatesService.services)
                }
                GhostButton { label: "later"; onTriggered: UpdatesService.services = [] }
              }
            }
          }

          // arch-update asks this after every run, in a terminal nobody sees.
          // Here it is a card with the names in it, at the wizard's width.
          OrphanCard {
            width: parent.width
            visible: UpdatesService.orphans.length > 0
            onDismissed: UpdatesService.orphans = []
          }

          Rectangle {
            width: parent.width
            visible: UpdatesService.rebootRequired
            implicitHeight: 46
            radius: Theme.radiusRow
            color: Theme.surface04
            border.width: 1
            border.color: Theme.hairline

            Text {
              anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
              text: "kernel updated — reboot when convenient"
              font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
              color: Theme.text2
            }
            Row {
              anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
              spacing: 6
              GhostButton { label: "reboot now"; onTriggered: UpdatesService.reboot() }
              GhostButton { label: "later"; onTriggered: UpdatesService.rebootRequired = false }
            }
          }

          Text {
            text: "unresolved pacnews park in settings → system"
            font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
            color: Theme.textDisabled
          }
        }

        // -- footer ---------------------------------------------------------------
        Item {
          width: parent.width
          height: 32

          Row {
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            spacing: 7

            GhostButton {
              visible: root.step === 1
              label: "cancel"
              onTriggered: frame.active = false
            }
            GhostButton {
              visible: root.step === 3 || root.entry === "failure"
              label: "view log"
              onTriggered: UpdatesService.openLog()
            }
          }

          UpdateButton {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            implicitWidth: 116
            visible: root.step === 1
            label: "update →"
            onTriggered: { root.step = 2; UpdatesService.apply() }
          }
          GhostButton {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: root.step === 3 || root.entry === "failure"
            label: "close"
            onTriggered: frame.active = false
          }
        }
      }

      component GhostButton: Rectangle {
        id: ghost
        property string label
        signal triggered()

        implicitWidth: ghostText.implicitWidth + 18
        implicitHeight: 24
        radius: Theme.radiusChip
        color: ghostHover.hovered ? Theme.surface07 : Theme.surface04
        border.width: 1
        border.color: Theme.hairline

        Text {
          id: ghostText
          anchors.centerIn: parent
          text: ghost.label
          font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
          color: Theme.text2
        }

        HoverHandler { id: ghostHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: ghost.triggered() }
      }
    }
  }
}
