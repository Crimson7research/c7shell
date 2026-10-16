import QtQuick
import C7

// What the panel says after a change tailscaled did not make. One file,
// because the sentence was written out three times -- the header's tooltip,
// the exit-node card and the settings card -- and because it now has to
// BRANCH, which three copies would have branched three times and eventually
// differently.
//
// Non-visual on purpose: the three sites draw it in three different places
// (two inline rows and a tooltip, at two colours), and what they have to share
// is the WORDING, not the styling. The contract publishes what failed and
// deliberately does not phrase it -- docs/architecture.md keeps presentation
// in QML -- so this file is where the phrasing lives.
//
// THE BRANCH IS ON `writable`, and that is sound rather than convenient: the
// backend moves that flag for a 403 and for nothing else, a 403 being
// tailscaled saying this process is not its operator. So the two readings are
//
//   writable false     a permission setting, which will not change under the
//                      running shell. The controls are dead, and the advice is
//                      actionable: c7shell-bootstrap exists to name this user.
//   writeError alone   one attempt went wrong -- a timeout, a daemon
//                      restarting mid-write, a 500, a socket that vanished.
//                      The control is still live, and the honest advice is to
//                      click it again.
//
// Saying the first for the second is what this branch is for. It was a
// confident, specific, wrong diagnosis under a panel whose every control had
// just gone permanently dead, telling the user to run a command that would not
// help.
//
// Both branches end in the daemon's own words, verbatim, which is also why
// every site that draws this sets Text.PlainText.
QtObject {
  readonly property string message: !Tailscale.writable
    ? qsTr("tailscaled refused the change: it takes orders only from root or its operator. Run c7shell-bootstrap to name this user. (%1)").arg(Tailscale.writeError)
    : Tailscale.writeError !== ""
      ? qsTr("tailscaled did not make the change — try again. (%1)").arg(Tailscale.writeError)
      : ""
}
