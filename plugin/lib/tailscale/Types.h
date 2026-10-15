#pragma once

#include <QtCore/QDateTime>
#include <QtCore/QList>
#include <QtCore/QString>
#include <QtCore/QStringList>

#include <optional>

namespace c7::tailscale {

// Where a peer sits in the device list: the signed-in user's own machines, then
// tagged ones (which have no owner), then everyone else's.
enum class Group { Mine, Tagged, Others };

// Defaults are set on every scalar: a field the parser forgets to fill reads
// as offline and unremarkable, not as indeterminate memory.
struct Peer {
    QString nodeId;
    QString hostName;
    QString ip4;
    QString ip6;
    QString dnsName;
    QString ownerName;
    bool online = false;
    Group group = Group::Others;
    bool exitNodeOption = false;
};

struct ExitNode {
    QString id;
    QString name;
    QString ip4;
    bool online = false;
};

// tailscaled reports the exit node's addresses as CIDR ("100.111.18.72/32")
// while a peer's own TailscaleIPs are bare, so the two never compare equal
// until the prefix is dropped.
QString stripMask(const QString &cidr);

// What `tailscale status --json` says, reduced to what the shell shows.
struct Status {
    QString backendState;
    QString selfName;
    QString selfIp4;
    QString selfIp6;
    QString selfDnsName;
    QDateTime keyExpiry;
    QStringList health;
    QString tailnet;
    std::optional<ExitNode> exitNode;
    QList<Peer> peers;
};

} // namespace c7::tailscale
