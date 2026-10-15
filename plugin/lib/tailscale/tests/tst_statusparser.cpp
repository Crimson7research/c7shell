#include "tailscale/StatusParser.h"

#include "testing/testmain.h"

#include <QtCore/QDate>
#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QTime>
#include <QtCore/QTimeZone>
#include <QtTest/QTest>

#include <algorithm>

using c7::tailscale::Group;
using c7::tailscale::Peer;
using c7::tailscale::StatusParser;
using c7::tailscale::stripMask;

namespace {

QByteArray readFixture(const char *name)
{
    QFile f(QStringLiteral(C7_FIXTURE_DIR "/") + QLatin1String(name));
    // An unreadable fixture must fail the test, not parse as "malformed".
    if (!f.open(QIODevice::ReadOnly))
        qFatal("cannot open fixture %s", name);
    return f.readAll();
}

int count(const QList<Peer> &peers, Group group)
{
    return int(std::count_if(peers.cbegin(), peers.cend(),
                             [group](const Peer &p) { return p.group == group; }));
}

Peer find(const QList<Peer> &peers, Group group)
{
    const auto it = std::find_if(peers.cbegin(), peers.cend(),
                                 [group](const Peer &p) { return p.group == group; });
    return it == peers.cend() ? Peer{} : *it;
}

// By the OS hostname on purpose: these tests are about the gap between that
// and the DNS label, so the lookup has to use the half that is NOT under test.
Peer byHostName(const QList<Peer> &peers, const QString &hostName)
{
    const auto it = std::find_if(peers.cbegin(), peers.cend(),
                                 [&hostName](const Peer &p) { return p.hostName == hostName; });
    return it == peers.cend() ? Peer{} : *it;
}

// Produces the one status tailscaled can genuinely emit but no capture holds:
// an ExitNodeStatus whose ID names a node that is no longer in the peer list.
QByteArray withoutPeer(const QByteArray &json, const QString &hostName)
{
    QJsonObject root = QJsonDocument::fromJson(json).object();
    QJsonObject peers = root.value(QLatin1String("Peer")).toObject();
    for (const QString &key : peers.keys()) {
        if (peers.value(key).toObject().value(QLatin1String("HostName")).toString() == hostName)
            peers.remove(key);
    }
    root.insert(QLatin1String("Peer"), peers);
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

} // namespace

class TestStatusParser : public QObject {
    Q_OBJECT

private slots:
    void parsesBackendStateAndHealth()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        QVERIFY(s.has_value());
        QCOMPARE(s->backendState, QStringLiteral("Running"));
        QCOMPARE(s->health.size(), 1);
        QVERIFY(s->health.first().contains(QStringLiteral("--accept-routes")));
        QCOMPARE(s->selfIp4, QStringLiteral("100.115.228.122"));
        QCOMPARE(s->tailnet, QStringLiteral("example.com"));
    }

    // Self's other two fields, which nothing else in this tree reads back.
    // Both are parsed off a key name and a date format that can be wrong
    // without anything failing: selfIp6 falls out of the same TailscaleIPs
    // array as selfIp4 but is told apart by the colon, and keyExpiry is a
    // string run through Qt::ISODate -- read the wrong key, or a format Qt
    // does not accept, and keyExpiry is simply invalid, the panel's
    // `keyExpires` is false and the expiry line silently never draws.
    void parsesSelfIp6AndKeyExpiry()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        QVERIFY(s.has_value());
        QCOMPARE(s->selfIp6, QStringLiteral("fd7a:115c:a1e0::fd27:82d8"));
        QVERIFY2(s->keyExpiry.isValid(), "the capture's Self.KeyExpiry did not parse at all");
        QCOMPARE(s->keyExpiry,
                 QDateTime(QDate(2027, 4, 11), QTime(9, 6, 8), QTimeZone::UTC));
    }

    // Absent, not merely empty: a node whose key never expires -- a tagged
    // node, or one with expiry disabled -- reports no KeyExpiry at all, and
    // the invalid QDateTime is what the panel reads as "no expiry line".
    void leavesKeyExpiryInvalidWhenTheNodeKeyNeverExpires()
    {
        const auto s = StatusParser::parse(
                QByteArrayLiteral("{\"BackendState\":\"Running\",\"Self\":{\"HostName\":\"x\"}}"));
        QVERIFY(s.has_value());
        QVERIFY(!s->keyExpiry.isValid());
    }

    // "no devices" and "this reply never described the tailnet" leave the same
    // empty peer list, and a caller that replaces its rows from the second
    // renders "network devices 0" for what was actually no answer. Only the
    // key's presence tells them apart.
    void saysWhetherTheReplyCarriedAPeerSectionAtAll()
    {
        QVERIFY(StatusParser::parse(readFixture("status-idle.json"))->hasPeerSection);
        const auto none = StatusParser::parse(QByteArrayLiteral("{\"BackendState\":\"Running\"}"));
        QVERIFY(none.has_value());
        QVERIFY(!none->hasPeerSection);
        QVERIFY(none->peers.isEmpty());
        // null is how tailscaled writes a map with nothing in it, and is no
        // more a description of the tailnet than an absent key is.
        const auto null = StatusParser::parse(
                QByteArrayLiteral("{\"BackendState\":\"Running\",\"Peer\":null}"));
        QVERIFY(!null->hasPeerSection);
        // An empty OBJECT is a description: a tailnet with no other devices.
        const auto empty = StatusParser::parse(
                QByteArrayLiteral("{\"BackendState\":\"Running\",\"Peer\":{}}"));
        QVERIFY(empty->hasPeerSection);
        QVERIFY(empty->peers.isEmpty());
    }

    void rejectsMalformedJson()
    {
        QVERIFY(!StatusParser::parse(QByteArrayLiteral("{\"Self\":")).has_value());
        QVERIFY(!StatusParser::parse(QByteArray()).has_value());
    }

    void groupsPeersByUserId()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        QCOMPARE(count(s->peers, Group::Mine), 10);
        QCOMPARE(count(s->peers, Group::Tagged), 8);
        QCOMPARE(count(s->peers, Group::Others), 2);
    }

    void namesTheOwnerOnlyForOtherUsers()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        const Peer other = find(s->peers, Group::Others);
        QVERIFY(!other.ownerName.isEmpty());
        QCOMPARE(find(s->peers, Group::Mine).ownerName, QString());
    }

    // The naming bug this module shipped with: the panel bound hostName, and
    // Tailscale names a device by its DNS label everywhere else. The capture's
    // `ip-172-31-0-10` is the shape that proves it -- a cloud instance whose OS
    // hostname is its private address and whose label is a word.
    void prefersTheDnsLabelOverTheHostName()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        const Peer p = byHostName(s->peers, QStringLiteral("ip-172-31-0-10"));
        QCOMPARE(p.displayName, QStringLiteral("host-5"));
        // The label, not the FQDN: the panel shows what the console shows.
        QCOMPARE(p.dnsName, QStringLiteral("host-5.example-tailnet.ts.net"));
        // Still the OS name, for whatever wants the OS name.
        QCOMPARE(p.hostName, QStringLiteral("ip-172-31-0-10"));
    }

    // MagicDNS off, or a node that never got a name: DNSName is "" and the
    // row has to fall back rather than draw blank.
    void fallsBackToTheHostNameWithoutMagicDns()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        const Peer p = byHostName(s->peers, QStringLiteral("xi"));
        QVERIFY2(p.dnsName.isEmpty(), "the fixture's MagicDNS-less peer grew a DNSName");
        QCOMPARE(p.displayName, QStringLiteral("xi"));
    }

    void joinsExitNodeNameFromItsPeer()
    {
        const auto s = StatusParser::parse(readFixture("status-exitnode.json"));
        QVERIFY(s->exitNode.has_value());
        QCOMPARE(s->exitNode->name, QStringLiteral("pentest-exit-node"));
        QCOMPARE(s->exitNode->online, true);
    }

    void fallsBackToTheIdWhenTheExitPeerIsMissing()
    {
        QByteArray j = readFixture("status-exitnode.json");
        j = withoutPeer(j, QStringLiteral("pentest-exit-node"));
        const auto s = StatusParser::parse(j);
        QVERIFY(s->exitNode.has_value());
        QCOMPARE(s->exitNode->name, s->exitNode->id);
        QVERIFY(!s->exitNode->name.isEmpty());
    }

    void stripsTheMaskFromExitNodeAddresses()
    {
        QCOMPARE(stripMask(QStringLiteral("100.101.102.103/32")), QStringLiteral("100.101.102.103"));
        QCOMPARE(stripMask(QStringLiteral("fd7a:115c:a1e0::aaaa:bbbb/128")),
                 QStringLiteral("fd7a:115c:a1e0::aaaa:bbbb"));
        QCOMPARE(stripMask(QStringLiteral("100.101.102.103")), QStringLiteral("100.101.102.103"));
    }
};

C7_TEST_MAIN(TestStatusParser)
#include "tst_statusparser.moc"
