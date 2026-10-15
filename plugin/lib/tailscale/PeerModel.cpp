#include "tailscale/PeerModel.h"

#include <QtCore/QSet>

#include <algorithm>
#include <utility>

namespace c7::tailscale {

namespace {

// Everything a row shows. A peer whose fields all still match needs no
// dataChanged, so a poll that found nothing new leaves every view untouched.
// nodeId is absent on purpose: two peers only ever reach here once their ids
// have already matched.
bool sameFields(const Peer &a, const Peer &b)
{
    return a.hostName == b.hostName && a.ip4 == b.ip4 && a.ip6 == b.ip6
        && a.dnsName == b.dnsName && a.online == b.online && a.group == b.group
        && a.ownerName == b.ownerName && a.exitNodeOption == b.exitNodeOption;
}

} // namespace

PeerModel::PeerModel(QObject *parent) : QAbstractListModel(parent) { }

int PeerModel::rowCount(const QModelIndex &parent) const
{
    // A list model has rows at the root and nowhere else.
    return parent.isValid() ? 0 : int(m_peers.size());
}

QVariant PeerModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_peers.size())
        return {};
    const Peer &p = m_peers.at(index.row());
    switch (role) {
    case HostNameRole:
        return p.hostName;
    case Ip4Role:
        return p.ip4;
    case Ip6Role:
        return p.ip6;
    case DnsNameRole:
        return p.dnsName;
    case OnlineRole:
        return p.online;
    case GroupRole:
        // As an int: Group is the library's own enum, and a view compares it
        // against the same values the C7 contract will expose.
        return int(p.group);
    case OwnerNameRole:
        return p.ownerName;
    case NodeIdRole:
        return p.nodeId;
    case ExitNodeOptionRole:
        return p.exitNodeOption;
    default:
        return {};
    }
}

QHash<int, QByteArray> PeerModel::roleNames() const
{
    return {
        {HostNameRole, "hostName"},
        {Ip4Role, "ip4"},
        {Ip6Role, "ip6"},
        {DnsNameRole, "dnsName"},
        {OnlineRole, "online"},
        {GroupRole, "group"},
        {OwnerNameRole, "ownerName"},
        {NodeIdRole, "nodeId"},
        {ExitNodeOptionRole, "exitNodeOption"},
    };
}

int PeerModel::rowOfNodeId(const QString &nodeId, int from) const
{
    for (int row = from; row < m_peers.size(); ++row) {
        if (m_peers.at(row).nodeId == nodeId)
            return row;
    }
    return -1;
}

void PeerModel::setPeers(const QList<Peer> &peers)
{
    QList<Peer> next = peers;
    // The same order StatusParser produces, applied again here because a
    // caller may hand over peers it assembled itself.
    std::sort(next.begin(), next.end(), precedes);

    QSet<QString> wanted;
    wanted.reserve(next.size());
    for (const Peer &p : std::as_const(next))
        wanted.insert(p.nodeId);

    // Backwards, so the rows still to be examined keep their numbers while
    // rows are leaving; neighbours go in one signal rather than one each.
    for (int last = int(m_peers.size()) - 1; last >= 0; --last) {
        if (wanted.contains(m_peers.at(last).nodeId))
            continue;
        int first = last;
        while (first > 0 && !wanted.contains(m_peers.at(first - 1).nodeId))
            --first;
        beginRemoveRows({}, first, last);
        m_peers.remove(first, last - first + 1);
        endRemoveRows();
        last = first;
    }

    // Walk the order the list should end up in, settling one row at a time.
    // Everything before `row` already matches, so a peer that is here but out
    // of place can only be further down -- which is why the move is always
    // upwards and its destination always outside the range being moved, the
    // one arrangement beginMoveRows() accepts without adjustment.
    for (int row = 0; row < next.size(); ++row) {
        const Peer &want = next.at(row);
        if (row >= m_peers.size() || m_peers.at(row).nodeId != want.nodeId) {
            const int from = rowOfNodeId(want.nodeId, row);
            if (from < 0) {
                beginInsertRows({}, row, row);
                m_peers.insert(row, want);
                endInsertRows();
                continue;
            }
            beginMoveRows({}, from, from, {}, row);
            m_peers.move(from, row);
            endMoveRows();
        }
        if (sameFields(m_peers.at(row), want))
            continue;
        m_peers[row] = want;
        emit dataChanged(index(row), index(row));
    }
}

} // namespace c7::tailscale
