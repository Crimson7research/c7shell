#pragma once

#include "tailscale/Types.h"

#include <QtCore/QAbstractListModel>
#include <QtCore/QList>

namespace c7::tailscale {

// The tailnet's devices as rows a view binds to. setPeers() diffs the new peer
// list against the rows already here and inserts, removes, moves or updates
// only what changed, so a row keeps its delegate -- and whatever the person is
// typing into it -- across a status update. It never resets the model:
// rebuilding every row on every poll is the bug this class exists to avoid.
//
// A row is identified by Peer::nodeId, tailscaled's own device id. Not the
// hostname, which repeats on a tailnet, and not the public key, which changes
// under a node that re-keys without the node itself changing.
class PeerModel : public QAbstractListModel {
    Q_OBJECT

public:
    enum Role {
        HostNameRole = Qt::UserRole + 1,
        Ip4Role,
        Ip6Role,
        DnsNameRole,
        OnlineRole,
        GroupRole,
        OwnerNameRole,
        NodeIdRole,
        ExitNodeOptionRole,
    };
    Q_ENUM(Role)

    explicit PeerModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // Sorted into the order the device list reads top to bottom, so a caller
    // holding an unsorted list need not sort it first.
    void setPeers(const QList<Peer> &peers);

private:
    int rowOfNodeId(const QString &nodeId, int from) const;

    QList<Peer> m_peers;
};

} // namespace c7::tailscale
