#include "tailscale/StatusParser.h"

#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>

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

} // namespace

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
    return s;
}

} // namespace c7::tailscale
