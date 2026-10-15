#include "tailscale/StatusParser.h"

#include "testing/testmain.h"

#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
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
        QCOMPARE(s->selfIp4, QStringLiteral("100.73.10.20"));
        QCOMPARE(s->tailnet, QStringLiteral("example.com"));
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
        QCOMPARE(stripMask(QStringLiteral("100.111.18.72/32")), QStringLiteral("100.111.18.72"));
        QCOMPARE(stripMask(QStringLiteral("fd7a:115c:a1e0::5101:1248/128")),
                 QStringLiteral("fd7a:115c:a1e0::5101:1248"));
        QCOMPARE(stripMask(QStringLiteral("100.111.18.72")), QStringLiteral("100.111.18.72"));
    }
};

C7_TEST_MAIN(TestStatusParser)
#include "tst_statusparser.moc"
