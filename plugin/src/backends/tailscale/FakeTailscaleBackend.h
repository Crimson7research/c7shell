#pragma once

#include "contracts/TailscaleBackend.h"
#include "tailscale/PeerModel.h"

// A TailscaleBackend a test drives by hand: every value is set through a
// setter, nothing is read from a socket and nothing is parsed. It is what
// lets a test put the contract in a state tailscaled would be awkward to talk
// into -- an exit node that went offline, a key about to expire, a tailnet
// with no peers -- and it is the proof that the contract is substitutable
// rather than a description of LocalApiTailscaleBackend.
//
// Built into tests only, never into the installed module. Being absent from
// qt_add_qml_module(c7 ... SOURCES), and listed in the test target's sources
// instead, is the entire mechanism: nothing checks it. The plugin gate
// inspects installed files, and a fake wrongly added to the module's SOURCES
// would compile into the one .so and be shipped without a word.
//
// Each setter emits only when the value moves, so a test can count signals
// and a redundant set is not mistaken for a change. The derived properties
// (selfDnsName's normalisation, exitNodeBlocked, issueCount) are deliberately
// not settable: they come from the contract, and a fake that could contradict
// them would test nothing.
class FakeTailscaleBackend : public TailscaleBackend {
    Q_OBJECT

public:
    explicit FakeTailscaleBackend(QObject *parent = nullptr) : TailscaleBackend(parent) {}

    State state() const override { return m_state; }
    QString selfName() const override { return m_selfName; }
    QString selfIp4() const override { return m_selfIp4; }
    QString selfIp6() const override { return m_selfIp6; }
    QString tailnet() const override { return m_tailnet; }
    QDateTime keyExpiry() const override { return m_keyExpiry; }
    bool exitNodeActive() const override { return m_exitNodeActive; }
    QString exitNodeId() const override { return m_exitNodeId; }
    QString exitNodeName() const override { return m_exitNodeName; }
    bool exitNodeOnline() const override { return m_exitNodeOnline; }
    QStringList issues() const override { return m_issues; }
    QAbstractItemModel *peers() const override { return &m_peers; }
    QAbstractItemModel *exitNodes() const override { return &m_exitNodes; }
    QString recommendedExitNodeId() const override { return m_recommendedExitNodeId; }
    bool writable() const override { return m_writable; }
    QString writeError() const override { return m_writeError; }
    bool exitNodeAllowLANAccess() const override { return m_exitNodeAllowLANAccess; }
    bool acceptRoutes() const override { return m_acceptRoutes; }
    bool acceptDns() const override { return m_acceptDns; }

    // The actions, recorded rather than performed: "setWantRunning(true)",
    // "setExitNode(nABC123CNTRL)". What a view is answerable for is WHAT it
    // asked for -- whether tailscaled then does it is the real backend's
    // business and the daemon's -- so a recording is the whole of what a test
    // of a control needs.
    //
    // Deliberately not also moving the matching property: a fake that applied
    // its own writes would be a fake of a tailscaled that never refuses
    // anything, and every test written against it would pass on a machine
    // where the panel does nothing at all.
    void setWantRunning(bool on) override { record(QStringLiteral("setWantRunning"), on); }
    void setExitNode(const QString &nodeId) override
    {
        record(QStringLiteral("setExitNode"), nodeId);
    }
    void setExitNodeAllowLANAccess(bool on) override
    {
        record(QStringLiteral("setExitNodeAllowLANAccess"), on);
    }
    void setAcceptRoutes(bool on) override { record(QStringLiteral("setAcceptRoutes"), on); }
    void setAcceptDns(bool on) override { record(QStringLiteral("setAcceptDns"), on); }

    QStringList calls() const { return m_calls; }
    void clearCalls() { m_calls.clear(); }

    void setState(State value) { set(m_state, value, &TailscaleBackend::stateChanged); }
    void setSelfName(const QString &v) { set(m_selfName, v, &TailscaleBackend::selfNameChanged); }
    void setSelfIp4(const QString &v) { set(m_selfIp4, v, &TailscaleBackend::selfIp4Changed); }
    void setSelfIp6(const QString &v) { set(m_selfIp6, v, &TailscaleBackend::selfIp6Changed); }
    // Takes the name as tailscaled writes it, root dot and all: a test that
    // could only set an already-stripped name could not catch the contract
    // forgetting to strip.
    void setRawSelfDnsName(const QString &v)
    {
        set(m_selfDnsName, v, &TailscaleBackend::selfDnsNameChanged);
    }
    void setTailnet(const QString &v) { set(m_tailnet, v, &TailscaleBackend::tailnetChanged); }
    void setKeyExpiry(const QDateTime &v)
    {
        set(m_keyExpiry, v, &TailscaleBackend::keyExpiryChanged);
    }
    void setExitNodeActive(bool v)
    {
        set(m_exitNodeActive, v, &TailscaleBackend::exitNodeActiveChanged);
    }
    void setExitNodeId(const QString &v)
    {
        set(m_exitNodeId, v, &TailscaleBackend::exitNodeIdChanged);
    }
    void setExitNodeName(const QString &v)
    {
        set(m_exitNodeName, v, &TailscaleBackend::exitNodeNameChanged);
    }
    void setExitNodeOnline(bool v)
    {
        set(m_exitNodeOnline, v, &TailscaleBackend::exitNodeOnlineChanged);
    }
    void setIssues(const QStringList &v) { set(m_issues, v, &TailscaleBackend::issuesChanged); }
    void setRecommendedExitNodeId(const QString &v)
    {
        set(m_recommendedExitNodeId, v, &TailscaleBackend::recommendedExitNodeIdChanged);
    }
    // The outcome of a write, which a test states because this fake never
    // attempts one: what a panel does after a 403 is a thing to put it in,
    // not a thing to wait for.
    void setWritable(bool v) { set(m_writable, v, &TailscaleBackend::writableChanged); }
    void setWriteError(const QString &v)
    {
        set(m_writeError, v, &TailscaleBackend::writeErrorChanged);
    }

    // The read-back side of the three switch actions, named `report...`
    // rather than `set...` for a reason worth having in the API: `setX` is
    // already taken by the ACTION, which only records. The two cannot share a
    // name because they are not the same thing -- one is a panel asking
    // tailscaled for something, the other is tailscaled having answered -- and
    // a test that wants a switch to move calls this one, which is the only
    // thing that moves one in the shell either.
    void reportExitNodeAllowLANAccess(bool v)
    {
        set(m_exitNodeAllowLANAccess, v, &TailscaleBackend::exitNodeAllowLANAccessChanged);
    }
    void reportAcceptRoutes(bool v) { set(m_acceptRoutes, v, &TailscaleBackend::acceptRoutesChanged); }
    void reportAcceptDns(bool v) { set(m_acceptDns, v, &TailscaleBackend::acceptDnsChanged); }

    // The models are the real PeerModel, not a stand-in: stable-row behaviour
    // is the library's and a fake of it would be a fake of our own code.
    void setPeers(const QList<c7::tailscale::Peer> &peers) { m_peers.setPeers(peers); }
    void setExitNodes(const QList<c7::tailscale::Peer> &peers) { m_exitNodes.setPeers(peers); }

protected:
    QString rawSelfDnsName() const override { return m_selfDnsName; }

private:
    template<typename T>
    void set(T &slot, const T &value, void (TailscaleBackend::*changed)())
    {
        if (slot == value)
            return;
        slot = value;
        emit(this->*changed)();
    }

    // Every call recorded, in order and including a repeat: clicking a switch
    // that is already on is a thing a view can do wrongly, and a recording
    // that collapsed it could not show that.
    void record(const QString &action, const QString &argument)
    {
        m_calls.append(action + u'(' + argument + u')');
    }
    void record(const QString &action, bool argument)
    {
        record(action, argument ? QStringLiteral("true") : QStringLiteral("false"));
    }

    State m_state = State::NoState;
    QString m_selfName;
    QString m_selfIp4;
    QString m_selfIp6;
    QString m_selfDnsName;
    QString m_tailnet;
    QDateTime m_keyExpiry;
    bool m_exitNodeActive = false;
    bool m_exitNodeOnline = false;
    QString m_exitNodeId;
    QString m_exitNodeName;
    QStringList m_issues;
    mutable c7::tailscale::PeerModel m_peers;
    mutable c7::tailscale::PeerModel m_exitNodes;
    QString m_recommendedExitNodeId;
    // True until refused, as the contract specifies: a fake that started
    // false would let a panel gated on it pass here and be dead in the shell.
    bool m_writable = true;
    QString m_writeError;
    // False until a /prefs says otherwise, as in the real backend: a fake that
    // started these at tailscaled's own defaults would be inventing a daemon
    // it has not heard from.
    bool m_exitNodeAllowLANAccess = false;
    bool m_acceptRoutes = false;
    bool m_acceptDns = false;
    QStringList m_calls;
};
