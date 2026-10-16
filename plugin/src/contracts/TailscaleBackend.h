#pragma once

#include <QtCore/QAbstractItemModel>
#include <QtCore/QDateTime>
#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtQml/qqmlregistration.h>

class QJSEngine;
class QQmlEngine;

// C7.Tailscale: the tailnet this machine is on -- its own identity, the state
// tailscaled reports, the exit node in use and the devices it can reach.
//
// The contract, not an implementation: every member below is state QML binds
// to or a collection it hands to a view, and a backend supplies all of it.
// LocalApiTailscaleBackend is the one backend today; it talks to tailscaled's
// local API socket. FakeTailscaleBackend, built into tests only, is the
// second -- the contract is substitutable or it is nothing.
//
// Every property here is read-only to QML; the changing is done by the
// actions, which ask the system rather than assigning to a property. Nothing
// on this class blocks: a property reads what the backend already knows,
// never what it would have to go and ask for, and an action returns before
// anything has happened.
//
// A property whose value is derived from other properties is computed here,
// not in a backend, and its getter is non-virtual: two backends must not be
// able to disagree about what `blocked` or a count means. How a derived
// property notifies follows one rule:
//
//   * derived from exactly one property -- it shares that property's NOTIFY
//     signal, so there is only ever one signal to emit and it cannot go stale
//     against its input (issueCount rides issuesChanged).
//   * derived from several -- it has its own NOTIFY signal, which this class
//     emits off each input's signal, wired in the constructor
//     (exitNodeBlocked). A backend emits only the inputs it owns and need not
//     know what else is built on them.
//
// Normalisation follows the same shape: where one form has to win, the public
// getter is non-virtual and normalises, and the pure virtual beneath it is
// what the backend stores (selfDnsName over rawSelfDnsName).
//
// A backend therefore stores first and emits second. The chaining is
// synchronous: a signal emitted before the member moves hands QML the old
// exitNodeBlocked, and nothing emits again to correct it.
//
// One escape exists from all of the above: a subclass redeclaring one of these
// Q_PROPERTYs shadows it, and QML then reads the subclass's declaration
// instead of the rule here. It takes writing the property out again, which is
// not something anyone does by accident -- but it is the way to get this
// wrong, so it is the thing to look for in review.
class TailscaleBackend : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Tailscale)
    QML_SINGLETON

    Q_PROPERTY(State state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString selfName READ selfName NOTIFY selfNameChanged)
    Q_PROPERTY(QString selfIp4 READ selfIp4 NOTIFY selfIp4Changed)
    Q_PROPERTY(QString selfIp6 READ selfIp6 NOTIFY selfIp6Changed)
    Q_PROPERTY(QString selfDnsName READ selfDnsName NOTIFY selfDnsNameChanged)
    Q_PROPERTY(QString tailnet READ tailnet NOTIFY tailnetChanged)
    Q_PROPERTY(QDateTime keyExpiry READ keyExpiry NOTIFY keyExpiryChanged)
    Q_PROPERTY(bool exitNodeActive READ exitNodeActive NOTIFY exitNodeActiveChanged)
    Q_PROPERTY(QString exitNodeId READ exitNodeId NOTIFY exitNodeIdChanged)
    Q_PROPERTY(QString exitNodeName READ exitNodeName NOTIFY exitNodeNameChanged)
    Q_PROPERTY(bool exitNodeOnline READ exitNodeOnline NOTIFY exitNodeOnlineChanged)
    Q_PROPERTY(bool exitNodeBlocked READ exitNodeBlocked NOTIFY exitNodeBlockedChanged)
    Q_PROPERTY(QStringList issues READ issues NOTIFY issuesChanged)
    Q_PROPERTY(int issueCount READ issueCount NOTIFY issuesChanged)
    Q_PROPERTY(QAbstractItemModel *peers READ peers CONSTANT)
    Q_PROPERTY(QAbstractItemModel *exitNodes READ exitNodes CONSTANT)
    Q_PROPERTY(QString recommendedExitNodeId READ recommendedExitNodeId NOTIFY
                   recommendedExitNodeIdChanged)
    Q_PROPERTY(bool writable READ writable NOTIFY writableChanged)
    Q_PROPERTY(QString writeError READ writeError NOTIFY writeErrorChanged)
    Q_PROPERTY(bool wantRunning READ wantRunning NOTIFY wantRunningChanged)
    Q_PROPERTY(bool exitNodeAllowLANAccess READ exitNodeAllowLANAccess NOTIFY
                   exitNodeAllowLANAccessChanged)
    Q_PROPERTY(bool acceptRoutes READ acceptRoutes NOTIFY acceptRoutesChanged)
    Q_PROPERTY(bool acceptDns READ acceptDns NOTIFY acceptDnsChanged)

public:
    // The six values tailscaled's BackendState actually reports. The macOS
    // menu names eight states, but the other two ("Waiting for Admin
    // Approval", "Waiting for Admin Signing") are read from tailnet-lock data,
    // not from this field. NoState is first and is the default: a backend that
    // has not heard from tailscaled yet reads as unknown, never as Stopped.
    //
    // NoState is also what a backend publishes when it loses tailscaled, and
    // it is then the only thing it changes. The rest of the snapshot stays as
    // tailscaled last described it, because blanking it would set
    // exitNodeActive to false and so drop exitNodeBlocked -- the fail-closed
    // flag going quiet exactly when the daemon behind it died.
    //
    // **A UI must therefore gate on state.** Peers, exit nodes, the exit-node
    // banner and the self identity are last-known values, not live ones, and
    // showing them while state is NoState renders a healthy tailnet served by
    // a daemon that is gone. Bind their visibility to `state !== NoState`.
    enum class State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running };
    Q_ENUM(State)

    // The derived-property wiring lives here, so a backend cannot forget it.
    // A signal-to-signal connection may announce exitNodeBlocked when its
    // value has not actually moved; a QML binding re-evaluating is cheap, a
    // fail-closed flag that fails to announce itself is not.
    explicit TailscaleBackend(QObject *parent = nullptr) : QObject(parent)
    {
        connect(this, &TailscaleBackend::exitNodeActiveChanged, this,
                &TailscaleBackend::exitNodeBlockedChanged);
        connect(this, &TailscaleBackend::exitNodeOnlineChanged, this,
                &TailscaleBackend::exitNodeBlockedChanged);
    }

    virtual State state() const = 0;

    // This machine on the tailnet.
    virtual QString selfName() const = 0;
    virtual QString selfIp4() const = 0;
    virtual QString selfIp6() const = 0;
    virtual QString tailnet() const = 0;
    // Invalid when the node key does not expire, which is what a tagged node
    // and a node with key expiry disabled both report.
    virtual QDateTime keyExpiry() const = 0;

    // The MagicDNS name of this machine, with no trailing root dot. tailscaled
    // writes Self's DNSName and a peer's the same way, fully qualified
    // ("host.tailnet.ts.net."), and the status parser strips the dot from
    // peers only. One form has to win where both first reach QML, and it wins
    // here: a backend stores what tailscaled sent and cannot opt out of the
    // normalisation by overriding the wrong member.
    QString selfDnsName() const { return withoutRootDot(rawSelfDnsName()); }

    virtual bool exitNodeActive() const = 0;
    // The selected exit node's string ID, matching a row's nodeId in
    // exitNodes. Empty when none is selected.
    //
    // It is here, beside the name, because a view has to be able to say WHICH
    // row is the one in use, and the name cannot: hostnames repeat on a
    // tailnet -- nothing stops two machines enrolling under one name -- so a
    // check mark joined on exitNodeName lands on every row that shares the
    // name with the node actually carrying the traffic. The ID is the only
    // peer identity the status, exit-node and suggestion endpoints all share;
    // NodeID is a number nothing joins on and a public key changes under a
    // node that re-keys. recommendedExitNodeId is joined the same way.
    virtual QString exitNodeId() const = 0;
    virtual QString exitNodeName() const = 0;
    // ExitNodeStatus.Online: whether the selected exit node can be reached.
    // Meaningless, and false, when no exit node is selected.
    virtual bool exitNodeOnline() const = 0;
    // The selected exit node cannot be reached, so tailscaled is dropping all
    // egress rather than leaking it onto the local network. The machine looks
    // connected and nothing works, and nothing else on this contract says why
    // -- which makes this the most valuable flag the module publishes. A UI
    // that shows one thing about Tailscale shows this.
    bool exitNodeBlocked() const { return exitNodeActive() && !exitNodeOnline(); }

    // tailscaled's own health warnings, verbatim, as it reports them. Empty
    // when it has nothing to complain about.
    virtual QStringList issues() const = 0;
    int issueCount() const { return int(issues().size()); }

    // Stable-row models a view binds to directly; never rebuilt, so a row
    // keeps its delegate across an update. Both are PeerModels, and exitNodes
    // holds only the peers offering themselves as one.
    //
    // Both outlive the connection that filled them -- see State -- so a view
    // shows them only while state !== NoState.
    virtual QAbstractItemModel *peers() const = 0;
    virtual QAbstractItemModel *exitNodes() const = 0;

    // The ID of the exit node /localapi/v0/suggest-exit-node picks, matching a
    // row's nodeId in exitNodes. Empty when it suggests none. It is the string
    // ID, the only peer identity the status, exit-node and suggestion
    // endpoints all share -- NodeID is a number nothing joins on, and a public
    // key changes under a node that re-keys.
    virtual QString recommendedExitNodeId() const = 0;

    // ---- The four prefs a switch on screen reads itself back from ----
    //
    // Each of these is the READ side of one of the actions below, and each
    // exists because the action alone was not enough. An action is a request
    // and publishes nothing, so a switch with no property under it can only
    // draw what was last clicked on it in this session: it opens at a default
    // on a machine that holds the opposite, it never hears a change made with
    // `tailscale set` elsewhere, and -- the one that matters -- a refused
    // write cannot spring it back, because there is nothing for it to spring
    // back to. That is a control that misreports the state it controls.
    //
    // They are ordinary published state like everything else above: the
    // backend reads them from the same /prefs it already fetches on every
    // pass, and the bus is what moves them. A UI binds a switch STRAIGHT to
    // one of these -- an accepted write puts a Prefs notification on the bus
    // within milliseconds and the re-read settles the value, which is both
    // faster than a person can see and the only reading that is true.
    //
    // No signal is shared and none is derived: a backend owns all four and
    // emits each as it moves.

    // prefs.WantRunning -- setWantRunning reads back here.
    //
    // IT IS NOT `state`, and the difference is the whole reason it is read
    // from the prefs rather than inferred. `state` is what tailscaled is
    // DOING; this is what it was last told to do. They disagree for as long
    // as a machine is Starting, and indefinitely on one that is NeedsLogin
    // with WantRunning true -- a machine tailscale is meant to be up on, and
    // on which a toggle drawn off `state` says the daemon was told to stop
    // when it was not. A UI wanting "is the tailnet actually up" has `state`
    // for that and should not read this; a UI drawing the CONTROL reads this.
    virtual bool wantRunning() const = 0;
    // prefs.ExitNodeAllowLANAccess -- setExitNodeAllowLANAccess reads back
    // here.
    virtual bool exitNodeAllowLANAccess() const = 0;
    // prefs.RouteAll -- setAcceptRoutes reads back here. Also the pref behind
    // the one health warning this module suppresses, so a UI that offers this
    // switch is the UI that can explain the suppression.
    virtual bool acceptRoutes() const = 0;
    // prefs.CorpDNS -- setAcceptDns reads back here.
    virtual bool acceptDns() const = 0;

    // ---- What this contract can change ----
    //
    // The first actions on any C7 contract, so the shape is spelt out once
    // here rather than guessed at twenty times. An action is
    // `Q_INVOKABLE virtual void ... = 0`: QML calls it on the singleton and a
    // backend decides what talking to the system means.
    //
    // AN ACTION IS A REQUEST, NOT A PROPERTY WRITE. It is named setX because
    // that is how a call site reads, but nothing on this object moves when one
    // is called. The action asks tailscaled to change; tailscaled's bus says
    // what it did; the bus is what moves the properties. A UI may draw the
    // clicked value at once, and the next notification decides what it settles
    // on -- so a toggle that was refused springs back, which is the entire
    // point. A backend that published the requested value itself would make a
    // refused write indistinguishable from an accepted one, and that is the
    // one outcome this module may not produce.
    //
    // IT RETURNS VOID AND IT DOES NOT BLOCK. An outcome that arrives later
    // cannot be a return value, and waiting for it is what
    // docs/architecture.md forbids, so every outcome an action has is
    // published as state: `writable` and `writeError` below.
    // NetworkBackend::connect() returning ConnectResult is not a
    // counter-example -- it answers a question decidable before anything is
    // attempted (does this network need a key), not the result of attempting.
    //
    // REFUSAL IS ORDINARY, not an error path to log and move past. tailscaled
    // authorises its local API by peer credentials: root, or the single user
    // named as its operator. Until c7shell-bootstrap has named this one, every
    // action below is refused -- measured, 403 "prefs write access denied" --
    // and a panel that cannot tell that apart from success is a panel full of
    // controls that silently do nothing.

    // Connect and disconnect this machine from the tailnet.
    Q_INVOKABLE virtual void setWantRunning(bool on) = 0;
    // Send egress through the peer with this id; an empty id selects none.
    //
    // THE ID, the same string exitNodeId publishes and a row of exitNodes is
    // keyed by -- never an IP address. tailscaled's prefs carry ExitNodeIP
    // beside ExitNodeID, a selection written into the wrong one is accepted
    // without complaint, and what it selects is nothing.
    Q_INVOKABLE virtual void setExitNode(const QString &nodeId) = 0;
    // Keep reaching this machine's own LAN while an exit node carries the
    // rest of its traffic. The control that matters most on a blocked exit
    // node: without it, an exit node that stops answering takes the printer,
    // the router's web UI and the NAS with it.
    Q_INVOKABLE virtual void setExitNodeAllowLANAccess(bool on) = 0;
    // Accept the subnet routes peers advertise. Also what the one suppressed
    // health warning is about -- see suppressedHealth() in the backend.
    Q_INVOKABLE virtual void setAcceptRoutes(bool on) = 0;
    // Use the tailnet's DNS configuration, MagicDNS included.
    Q_INVOKABLE virtual void setAcceptDns(bool on) = 0;

    // TRUE UNTIL A WRITE IS REFUSED, false from a refusal until one is
    // accepted again. READ THE NAME CAREFULLY: it is not a precondition and
    // not permission to try. It says only whether the last attempt was
    // refused, so the honest reading of it is "not known to be refused", and
    // a true here is a claim about the past rather than a promise about the
    // next click.
    //
    // THE NAME IS THE TRAP, which is worth saying because it has already
    // caused one: read as a precondition it invites gating a control on it,
    // and a `writable` that began false would then disable every control on a
    // machine where writing works perfectly -- with no way left to make the
    // first write that would enable them. So it starts true and the first
    // refusal is what moves it.
    //
    // Pre-checking is the alternative and is deliberately not taken.
    // tailscaled can be asked (POST /localapi/v0/check-prefs is gated the same
    // way and changes nothing), but that is a fourth endpoint in the connect
    // sequence, and this module has already spent a fix round REMOVING an
    // optional endpoint from that sequence because a failure there took the
    // whole backend to NoState. The first click answers the question for
    // free.
    //
    // What it is for is the moment after a refusal, when a toggle has sprung
    // back to where it was and the panel has to say why. A control may
    // reasonably go dead once this is false -- that is "disabled after a
    // refusal", which is a different thing from disabled until proven.
    virtual bool writable() const = 0;
    // Why the last change failed, in the words of whatever refused it, or
    // empty after one that was accepted. Published rather than phrased: the
    // wording a user reads -- that tailscaled takes orders only from root or
    // its operator, and that c7shell-bootstrap names one -- is presentation,
    // and docs/architecture.md keeps presentation in QML.
    virtual QString writeError() const = 0;

    // The singleton factory picks the backend. A configurable choice comes
    // only when a second backend exists.
    static TailscaleBackend *create(QQmlEngine *, QJSEngine *);

signals:
    void stateChanged();
    void selfNameChanged();
    void selfIp4Changed();
    void selfIp6Changed();
    void selfDnsNameChanged();
    void tailnetChanged();
    void keyExpiryChanged();
    void exitNodeActiveChanged();
    void exitNodeIdChanged();
    void exitNodeNameChanged();
    void exitNodeOnlineChanged();
    // Emitted by this class off the two signals above, never by a backend.
    void exitNodeBlockedChanged();
    void issuesChanged();
    void recommendedExitNodeIdChanged();
    void writableChanged();
    void writeErrorChanged();
    void wantRunningChanged();
    void exitNodeAllowLANAccessChanged();
    void acceptRoutesChanged();
    void acceptDnsChanged();

protected:
    // What tailscaled gave for Self's DNSName, root dot and all. A backend
    // stores it as it arrived; selfDnsName() is what QML sees.
    virtual QString rawSelfDnsName() const = 0;

private:
    static QString withoutRootDot(const QString &dnsName)
    {
        return dnsName.endsWith(u'.') ? dnsName.chopped(1) : dnsName;
    }
};
