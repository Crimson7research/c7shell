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
// Built into tests only, never into the installed module: it is absent from
// qt_add_qml_module(c7 ... SOURCES), which is why `cmake --install` cannot
// ship it.
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
    QString exitNodeName() const override { return m_exitNodeName; }
    bool exitNodeOnline() const override { return m_exitNodeOnline; }
    QStringList issues() const override { return m_issues; }
    QAbstractItemModel *peers() const override { return &m_peers; }
    QAbstractItemModel *exitNodes() const override { return &m_exitNodes; }
    QString recommendedExitNodeId() const override { return m_recommendedExitNodeId; }

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

    State m_state = State::NoState;
    QString m_selfName;
    QString m_selfIp4;
    QString m_selfIp6;
    QString m_selfDnsName;
    QString m_tailnet;
    QDateTime m_keyExpiry;
    bool m_exitNodeActive = false;
    bool m_exitNodeOnline = false;
    QString m_exitNodeName;
    QStringList m_issues;
    mutable c7::tailscale::PeerModel m_peers;
    mutable c7::tailscale::PeerModel m_exitNodes;
    QString m_recommendedExitNodeId;
};
