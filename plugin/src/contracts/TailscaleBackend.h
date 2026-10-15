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
// Everything here is read-only to QML. Nothing on this class blocks: a
// property reads what the backend already knows, never what it would have to
// go and ask for.
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
