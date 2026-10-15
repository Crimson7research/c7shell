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

// The name Tailscale itself shows: the first label of the MagicDNS name, with
// the tailnet's domain dropped. "" when the node has no MagicDNS name at all,
// which is the caller's cue to fall back to the OS hostname.
QString firstLabel(const QString &dnsName)
{
    const qsizetype dot = dnsName.indexOf(QLatin1Char('.'));
    return dot < 0 ? dnsName : dnsName.left(dot);
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

} // namespace

bool precedes(const Peer &a, const Peer &b)
{
    if (a.group != b.group)
        return a.group < b.group;
    if (a.online != b.online)
        return a.online;
    // By the name the list DRAWS, so the order it reads in is the order it is
    // sorted by: a row labelled with its DNS label but sorted on the OS
    // hostname underneath lands wherever that hostname falls -- a cloud
    // instance among the numbers -- and the list reads as unsorted.
    const int byDisplayName = a.displayName.compare(b.displayName, Qt::CaseInsensitive);
    if (byDisplayName != 0)
        return byDisplayName < 0;
    // Kept as the next key rather than dropped: a Peer assembled by hand --
    // a test, a fake backend -- may carry no displayName at all, and without
    // this such a list would fall straight through to nodeId and come out in
    // an order nobody wrote down.
    const int byHostName = a.hostName.compare(b.hostName, Qt::CaseInsensitive);
    if (byHostName != 0)
        return byHostName < 0;
    return a.nodeId < b.nodeId;
}

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
    // isObject(), not "empty": a tailnet with no other devices and a reply
    // that is not a status both leave `peers` empty, and only the key's
    // presence tells them apart.
    const QJsonValue peerSection = root.value(QLatin1String("Peer"));
    s.hasPeerSection = peerSection.isObject();
    const QJsonObject peers = peerSection.toObject();
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
        // MagicDNS off, or a node that never got a name, leaves DNSName empty
        // and the OS hostname is then the only name there is.
        p.displayName = p.dnsName.isEmpty() ? p.hostName : firstLabel(p.dnsName);
        p.online = peer.value(QLatin1String("Online")).toBool();
        p.exitNodeOption = peer.value(QLatin1String("ExitNodeOption")).toBool();
        p.group = groupOf(peer, users, selfUserId, &p.ownerName);
        s.peers.append(p);
    }
    // The Peer member order in the JSON is tailscaled's own and carries no
    // meaning; precedes() is the order the panel reads.
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
                e.name = p.displayName;
                break;
            }
        }
        s.exitNode = e;
    }
    return s;
}

} // namespace c7::tailscale
