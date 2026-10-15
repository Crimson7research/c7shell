#include "tailscale/StatusParser.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>

#include <algorithm>
#include <utility>

namespace c7::tailscale {

namespace {

// tailscaled lists one IPv4 and one IPv6 address per node, in no fixed order.
enum class Family { V4, V6 };

QString addressOf(const QJsonArray &ips, Family family)
{
    for (const QJsonValue &ip : ips) {
        const QString s = ip.toString();
        if (s.contains(QLatin1Char(':')) == (family == Family::V6))
            return s;
    }
    return {};
}

QString withoutTrailingDot(const QString &dnsName)
{
    return dnsName.endsWith(QLatin1Char('.')) ? dnsName.chopped(1) : dnsName;
}

// Tailscale files every tagged node under one synthetic user, so the three
// sections are a plain group-by on UserID. The tags themselves are tailnet
// policy and are deliberately not read: their names mean nothing here.
//
// `ownerName` is filled only for Others, because the Mine and Tagged headings
// already say who owns the rows beneath them.
Group groupOf(const QJsonObject &peer, const QJsonObject &users, qint64 selfUserId,
              QString *ownerName)
{
    const qint64 userId = peer.value(QLatin1String("UserID")).toInteger();
    const QJsonObject user = users.value(QString::number(userId)).toObject();
    if (user.value(QLatin1String("LoginName")).toString() == QLatin1String("tagged-devices"))
        return Group::Tagged;
    if (userId == selfUserId)
        return Group::Mine;
    *ownerName = user.value(QLatin1String("DisplayName")).toString();
    return Group::Others;
}

// The Peer member order in the JSON is tailscaled's own and carries no
// meaning, so the list is sorted into the order the panel reads top to bottom:
// section, then offline last, then hostname. nodeId breaks the final tie,
// because hostnames repeat on a tailnet and an unstable order flakes tests.
bool precedes(const Peer &a, const Peer &b)
{
    if (a.group != b.group)
        return a.group < b.group;
    if (a.online != b.online)
        return a.online;
    const int byHostName = a.hostName.compare(b.hostName, Qt::CaseInsensitive);
    if (byHostName != 0)
        return byHostName < 0;
    return a.nodeId < b.nodeId;
}

} // namespace

QString stripMask(const QString &cidr)
{
    const qsizetype slash = cidr.indexOf(QLatin1Char('/'));
    return slash < 0 ? cidr : cidr.left(slash);
}

std::optional<Status> StatusParser::parse(const QByteArray &json)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return std::nullopt;

    const QJsonObject root = doc.object();
    const QJsonObject self = root.value(QLatin1String("Self")).toObject();
    const QJsonArray selfIps = self.value(QLatin1String("TailscaleIPs")).toArray();

    Status s;
    s.backendState = root.value(QLatin1String("BackendState")).toString();
    s.selfName = self.value(QLatin1String("HostName")).toString();
    s.selfIp4 = addressOf(selfIps, Family::V4);
    s.selfIp6 = addressOf(selfIps, Family::V6);
    s.selfDnsName = self.value(QLatin1String("DNSName")).toString();
    // Absent when the node key never expires; the invalid QDateTime says so.
    s.keyExpiry = QDateTime::fromString(self.value(QLatin1String("KeyExpiry")).toString(), Qt::ISODate);
    // Health is null, not [], on a healthy node.
    for (const QJsonValue &h : root.value(QLatin1String("Health")).toArray())
        s.health.append(h.toString());
    s.tailnet = root.value(QLatin1String("CurrentTailnet")).toObject().value(QLatin1String("Name")).toString();

    const QJsonObject users = root.value(QLatin1String("User")).toObject();
    const qint64 selfUserId = self.value(QLatin1String("UserID")).toInteger();
    const QJsonObject peers = root.value(QLatin1String("Peer")).toObject();
    s.peers.reserve(peers.size());
    for (const QJsonValue &value : peers) {
        const QJsonObject peer = value.toObject();
        const QJsonArray ips = peer.value(QLatin1String("TailscaleIPs")).toArray();
        Peer p;
        // Identity is ID, never PublicKey: a node that re-keys keeps its ID,
        // and keying on the key would split it into two devices.
        p.nodeId = peer.value(QLatin1String("ID")).toString();
        p.hostName = peer.value(QLatin1String("HostName")).toString();
        p.ip4 = addressOf(ips, Family::V4);
        p.ip6 = addressOf(ips, Family::V6);
        // The MagicDNS name is fully qualified, trailing root dot and all.
        p.dnsName = withoutTrailingDot(peer.value(QLatin1String("DNSName")).toString());
        p.online = peer.value(QLatin1String("Online")).toBool();
        p.exitNodeOption = peer.value(QLatin1String("ExitNodeOption")).toBool();
        p.group = groupOf(peer, users, selfUserId, &p.ownerName);
        s.peers.append(p);
    }
    std::sort(s.peers.begin(), s.peers.end(), precedes);

    // Missing while no exit node is selected — on some builds absent, on others
    // null, which isObject() treats alike.
    const QJsonValue exitStatus = root.value(QLatin1String("ExitNodeStatus"));
    if (exitStatus.isObject()) {
        const QJsonObject status = exitStatus.toObject();
        ExitNode e;
        e.id = status.value(QLatin1String("ID")).toString();
        // This Online, not the peer's: it is what says the exit node is
        // reachable rather than blocking the connection.
        e.online = status.value(QLatin1String("Online")).toBool();
        e.ip4 = stripMask(addressOf(status.value(QLatin1String("TailscaleIPs")).toArray(), Family::V4));
        // ExitNodeStatus carries no hostname, so the label is joined from the
        // peer list; a node that has left the tailnet keeps its id as its name
        // rather than leaving the panel blank.
        e.name = e.id;
        for (const Peer &p : std::as_const(s.peers)) {
            if (p.nodeId == e.id) {
                e.name = p.hostName;
                break;
            }
        }
        s.exitNode = e;
    }
    return s;
}

} // namespace c7::tailscale
