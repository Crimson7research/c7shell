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
// local API socket. A second backend replaces that without the UI noticing,
// which is the whole reason this class is abstract.
//
// Everything here is read-only to QML. Nothing on this class blocks: a
// property reads what the backend already knows, never what it would have to
// go and ask for.
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
    Q_PROPERTY(QString exitNodeName READ exitNodeName NOTIFY exitNodeNameChanged)
    Q_PROPERTY(bool exitNodeBlocked READ exitNodeBlocked NOTIFY exitNodeBlockedChanged)
    Q_PROPERTY(QStringList issues READ issues NOTIFY issuesChanged)
    // Derived from issues, so it rides the same signal: a binding on either
    // re-evaluates whenever the health list changes.
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
    enum class State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running };
    Q_ENUM(State)

    explicit TailscaleBackend(QObject *parent = nullptr) : QObject(parent) {}

    virtual State state() const = 0;

    // This machine on the tailnet. selfDnsName is a MagicDNS name with no
    // trailing root dot -- see withoutRootDot().
    virtual QString selfName() const = 0;
    virtual QString selfIp4() const = 0;
    virtual QString selfIp6() const = 0;
    virtual QString selfDnsName() const = 0;
    virtual QString tailnet() const = 0;
    // Invalid when the node key does not expire, which is what a tagged node
    // and a node with key expiry disabled both report.
    virtual QDateTime keyExpiry() const = 0;

    virtual bool exitNodeActive() const = 0;
    virtual QString exitNodeName() const = 0;
    // exitNodeActive && !ExitNodeStatus.Online: the selected exit node cannot
    // be reached, so tailscaled is dropping all egress rather than leaking it
    // onto the local network. The machine looks connected and nothing works,
    // and nothing else on this contract says why -- which makes this the most
    // valuable flag the module publishes. A UI that shows one thing about
    // Tailscale shows this.
    virtual bool exitNodeBlocked() const = 0;

    // tailscaled's own health warnings, verbatim, newest-first as it reports
    // them. Empty when it has nothing to complain about.
    virtual QStringList issues() const = 0;
    virtual int issueCount() const = 0;

    // Stable-row models a view binds to directly; never rebuilt, so a row
    // keeps its delegate across an update. Both are PeerModels, and exitNodes
    // holds only the peers offering themselves as one.
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
    void exitNodeNameChanged();
    void exitNodeBlockedChanged();
    void issuesChanged();
    void recommendedExitNodeIdChanged();

protected:
    // tailscaled writes a peer's DNSName and Self's the same way, fully
    // qualified with the root dot ("host.tailnet.ts.net."), and the status
    // parser strips it from peers only. One convention has to win where both
    // first reach QML, and it wins here rather than in each backend, so no
    // name downstream ever carries a stray dot on the end.
    static QString withoutRootDot(const QString &dnsName)
    {
        return dnsName.endsWith(u'.') ? dnsName.chopped(1) : dnsName;
    }
};
