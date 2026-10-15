#pragma once

#include "contracts/TailscaleBackend.h"
#include "tailscale/PeerModel.h"

// The TailscaleBackend that reads tailscaled's local API socket: GET /status,
// /prefs and /suggest-exit-node, plus the /watch-ipn-bus stream that pushes
// every later change. Nothing here spawns the `tailscale` CLI, and nothing
// here polls.
//
// It does not open the socket yet. Every member below holds the value a
// machine that has not reported in has, which is what makes the singleton
// loadable -- and pins the starting state -- before any of it is wired up.
class LocalApiTailscaleBackend : public TailscaleBackend {
    Q_OBJECT

public:
    explicit LocalApiTailscaleBackend(QObject *parent = nullptr);

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

    // Owned by this object and outliving every binding on it, so a view may
    // hold the pointer for as long as the singleton lives.
    QAbstractItemModel *peers() const override { return &m_peers; }
    QAbstractItemModel *exitNodes() const override { return &m_exitNodes; }

    QString recommendedExitNodeId() const override { return m_recommendedExitNodeId; }

protected:
    QString rawSelfDnsName() const override { return m_selfDnsName; }

private:
    State m_state = State::NoState;

    QString m_selfName;
    QString m_selfIp4;
    QString m_selfIp6;
    QString m_selfDnsName; // as tailscaled reports it, root dot and all
    QString m_tailnet;
    QDateTime m_keyExpiry;

    bool m_exitNodeActive = false;
    // False until an exit node is known to be reachable: the fail-closed flag
    // built on this must not start out saying traffic is fine.
    bool m_exitNodeOnline = false;
    QString m_exitNodeName;

    QStringList m_issues;

    // Members, so they live exactly as long as the singleton a view binds
    // them to. mutable only because a property READ is const while the model
    // QML receives cannot be.
    mutable c7::tailscale::PeerModel m_peers;
    mutable c7::tailscale::PeerModel m_exitNodes;

    QString m_recommendedExitNodeId;
};
