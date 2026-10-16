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
    // What a device is CALLED: the first label of dnsName, which is the name
    // the admin console, the macOS app and MagicDNS all use. hostName is the
    // OS hostname underneath it, and the two differ often enough that binding
    // a view to hostName names six of twenty devices wrong on the tailnet
    // this was measured against -- including two phones that both answer to
    // `localhost`. Falls back to hostName when MagicDNS is off.
    QString displayName;
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

// tailscaled reports the exit node's addresses as CIDR ("100.101.102.103/32")
// while a peer's own TailscaleIPs are bare, so the two never compare equal
// until the prefix is dropped.
QString stripMask(const QString &cidr);

// The order the device list reads top to bottom: section, then offline last,
// then the NAME ON THE ROW -- displayName, case-insensitively, with hostName
// behind it for a Peer that carries no display name. nodeId breaks the final
// tie, because names repeat on a tailnet and an order that depends on where a
// peer sat in tailscaled's JSON is no order at all. Declared here, and used by
// both the parser and the model, so the list cannot end up sorted two ways.
bool precedes(const Peer &a, const Peer &b);

// What `tailscale status --json` says, reduced to what the shell shows.
struct Status {
    QString backendState;
    // This device, named by the same rule as Peer::displayName: the DNS
    // label, falling back to the OS hostname. It is a device on the tailnet
    // like any other and the console names it the same way.
    QString selfName;
    QString selfIp4;
    QString selfIp6;
    QString selfDnsName;
    QDateTime keyExpiry;
    QStringList health;
    QString tailnet;
    std::optional<ExitNode> exitNode;
    QList<Peer> peers;
    // Whether the reply carried a `Peer` object at all. `peers` is empty for
    // a tailnet with no other devices AND for a reply that never described
    // the tailnet, and a caller replacing its rows from the second renders
    // "network devices 0" for what was actually no answer. An empty Peer
    // object sets this; an absent or null one does not.
    bool hasPeerSection = false;
};

} // namespace c7::tailscale
