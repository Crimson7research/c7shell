#include "tailscale/PeerModel.h"
#include "tailscale/StatusParser.h"

#include "testing/testmain.h"

#include <QtCore/QFile>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

using c7::tailscale::Group;
using c7::tailscale::Peer;
using c7::tailscale::PeerModel;
using c7::tailscale::StatusParser;

namespace {

QByteArray readFixture(const char *name)
{
    QFile f(QStringLiteral(C7_FIXTURE_DIR "/") + QLatin1String(name));
    // An unreadable fixture must fail the test, not parse as "malformed".
    if (!f.open(QIODevice::ReadOnly))
        qFatal("cannot open fixture %s", name);
    return f.readAll();
}

Peer peer(const char *nodeId, const char *hostName, bool online = true, Group group = Group::Mine)
{
    Peer p;
    p.nodeId = QLatin1String(nodeId);
    p.hostName = QLatin1String(hostName);
    p.dnsName = p.hostName + QStringLiteral(".example-tailnet.ts.net");
    p.online = online;
    p.group = group;
    return p;
}

// One name, two machines -- which a tailnet really does hold. A model keyed on
// the hostname would show one row here.
QList<Peer> twoPeersSameHostNameDifferentIds()
{
    return {peer("nAAA1CNTRL", "zeta"), peer("nBBB1CNTRL", "zeta")};
}

// The same two devices, nAAA now offline, so it belongs below nBBB.
QList<Peer> sameTwoPeersOneNowOffline()
{
    return {peer("nAAA1CNTRL", "zeta", false), peer("nBBB1CNTRL", "zeta")};
}

QList<Peer> threePeers()
{
    return {peer("nA1CNTRL", "alpha"), peer("nB1CNTRL", "bravo"), peer("nC1CNTRL", "charlie")};
}

QList<Peer> threePeersMinusTheMiddleOne()
{
    return {peer("nA1CNTRL", "alpha"), peer("nC1CNTRL", "charlie")};
}

QModelIndex lastRowOfGroup(const PeerModel &m, Group group)
{
    QModelIndex last;
    for (int row = 0; row < m.rowCount(); ++row) {
        const QModelIndex i = m.index(row, 0);
        if (i.data(PeerModel::GroupRole).toInt() == int(group))
            last = i;
    }
    return last;
}

QModelIndex rowOfHostName(const PeerModel &m, const QString &hostName)
{
    for (int row = 0; row < m.rowCount(); ++row) {
        const QModelIndex i = m.index(row, 0);
        if (i.data(PeerModel::HostNameRole).toString() == hostName)
            return i;
    }
    return {};
}

} // namespace

class TestPeerModel : public QObject {
    Q_OBJECT

private slots:
    void keepsRowIdentityAcrossAnUpdate()
    {
        PeerModel m;
        m.setPeers(twoPeersSameHostNameDifferentIds());
        QSignalSpy reset(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy changed(&m, &QAbstractItemModel::dataChanged);
        m.setPeers(sameTwoPeersOneNowOffline());
        QCOMPARE(m.rowCount(), 2);                 // not collapsed to one
        QCOMPARE(reset.count(), 0);                // updated in place
        QVERIFY(changed.count() > 0);
    }

    void ordersGroupsThenOfflineLast()
    {
        PeerModel m;
        m.setPeers(StatusParser::parse(readFixture("status-idle.json"))->peers);
        QCOMPARE(m.index(0, 0).data(PeerModel::GroupRole).toInt(), int(Group::Mine));
        QVERIFY(lastRowOfGroup(m, Group::Mine).data(PeerModel::OnlineRole).toBool() == false);
    }

    void insertsAndRemovesRatherThanResetting()
    {
        PeerModel m;
        m.setPeers(threePeers());
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        m.setPeers(threePeersMinusTheMiddleOne());
        QCOMPARE(m.rowCount(), 2);
        QCOMPARE(removed.count(), 1);
    }

    // A device that goes offline sorts below the ones still up. It has to get
    // there by moving: a remove and an insert hand the view a fresh delegate,
    // which is the lost-password bug this model exists to prevent.
    void movesARowRatherThanRebuildingIt()
    {
        PeerModel m;
        m.setPeers(twoPeersSameHostNameDifferentIds());
        QCOMPARE(m.index(0, 0).data(PeerModel::NodeIdRole).toString(),
                 QStringLiteral("nAAA1CNTRL"));
        QSignalSpy moved(&m, &QAbstractItemModel::rowsMoved);
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        QSignalSpy inserted(&m, &QAbstractItemModel::rowsInserted);
        m.setPeers(sameTwoPeersOneNowOffline());
        QCOMPARE(moved.count(), 1);
        QCOMPARE(removed.count(), 0);
        QCOMPARE(inserted.count(), 0);
        QCOMPARE(m.index(0, 0).data(PeerModel::NodeIdRole).toString(),
                 QStringLiteral("nBBB1CNTRL"));
        QCOMPARE(m.index(1, 0).data(PeerModel::OnlineRole).toBool(), false);
    }

    void insertsANewPeerInPlace()
    {
        PeerModel m;
        m.setPeers(threePeersMinusTheMiddleOne());
        QSignalSpy reset(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy inserted(&m, &QAbstractItemModel::rowsInserted);
        m.setPeers(threePeers());
        QCOMPARE(m.rowCount(), 3);
        QCOMPARE(reset.count(), 0);
        QCOMPARE(inserted.count(), 1);
        // bravo sorts between the two rows already there.
        QCOMPARE(inserted.first().at(1).toInt(), 1);
        QCOMPARE(m.index(1, 0).data(PeerModel::HostNameRole).toString(),
                 QStringLiteral("bravo"));
    }

    void leavesUntouchedRowsAlone()
    {
        PeerModel m;
        m.setPeers(threePeers());
        QSignalSpy changed(&m, &QAbstractItemModel::dataChanged);
        m.setPeers(threePeers());
        QCOMPARE(changed.count(), 0);
    }

    // Task 2's tests pin only how many peers land in each group, so swapping
    // HostName for DNSName, or ID for NodeID, would pass them. gamma answers to
    // the DNS label host-1, which makes it the pair most easily crossed.
    void pinsAKnownPeersFields()
    {
        PeerModel m;
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        QVERIFY(s.has_value());
        m.setPeers(s->peers);
        const QModelIndex gamma = rowOfHostName(m, QStringLiteral("gamma"));
        QVERIFY(gamma.isValid());
        QCOMPARE(gamma.data(PeerModel::HostNameRole).toString(), QStringLiteral("gamma"));
        QCOMPARE(gamma.data(PeerModel::DnsNameRole).toString(),
                 QStringLiteral("host-1.example-tailnet.ts.net"));
        // And the row is labelled by the LABEL, not by either of those two.
        QCOMPARE(gamma.data(PeerModel::DisplayNameRole).toString(), QStringLiteral("host-1"));
        QCOMPARE(gamma.data(PeerModel::NodeIdRole).toString(),
                 QStringLiteral("nPFCxlUqVJ11CNTRL"));
        QCOMPARE(gamma.data(PeerModel::Ip4Role).toString(), QStringLiteral("100.67.243.58"));
        QCOMPARE(gamma.data(PeerModel::Ip6Role).toString(),
                 QStringLiteral("fd7a:115c:a1e0::8d19:e3a4"));
        QCOMPARE(gamma.data(PeerModel::GroupRole).toInt(), int(Group::Tagged));
        QCOMPARE(gamma.data(PeerModel::OnlineRole).toBool(), true);
    }

    void pinsTheOwnerAndExitNodeRoles()
    {
        PeerModel m;
        m.setPeers(StatusParser::parse(readFixture("status-idle.json"))->peers);
        const QModelIndex beta = rowOfHostName(m, QStringLiteral("beta"));
        QCOMPARE(beta.data(PeerModel::GroupRole).toInt(), int(Group::Others));
        QCOMPARE(beta.data(PeerModel::OwnerNameRole).toString(),
                 QStringLiteral("Second Example"));
        QCOMPARE(rowOfHostName(m, QStringLiteral("pentest-exit-node"))
                     .data(PeerModel::ExitNodeOptionRole).toBool(), true);
        QCOMPARE(beta.data(PeerModel::ExitNodeOptionRole).toBool(), false);
    }

    // A view reads rows by these names, so they are part of the contract.
    void namesEveryRoleForViews()
    {
        PeerModel m;
        const QHash<int, QByteArray> names = m.roleNames();
        QCOMPARE(names.value(PeerModel::HostNameRole), QByteArrayLiteral("hostName"));
        QCOMPARE(names.value(PeerModel::DisplayNameRole), QByteArrayLiteral("displayName"));
        QCOMPARE(names.value(PeerModel::Ip4Role), QByteArrayLiteral("ip4"));
        QCOMPARE(names.value(PeerModel::Ip6Role), QByteArrayLiteral("ip6"));
        QCOMPARE(names.value(PeerModel::DnsNameRole), QByteArrayLiteral("dnsName"));
        QCOMPARE(names.value(PeerModel::OnlineRole), QByteArrayLiteral("online"));
        QCOMPARE(names.value(PeerModel::GroupRole), QByteArrayLiteral("group"));
        QCOMPARE(names.value(PeerModel::OwnerNameRole), QByteArrayLiteral("ownerName"));
        QCOMPARE(names.value(PeerModel::NodeIdRole), QByteArrayLiteral("nodeId"));
        QCOMPARE(names.value(PeerModel::ExitNodeOptionRole),
                 QByteArrayLiteral("exitNodeOption"));
        // Qt's default roles must not leak in alongside them.
        QCOMPARE(names.size(), 10);
    }

    void answersNothingOffTheEndOrBeneathARow()
    {
        PeerModel m;
        QCOMPARE(m.rowCount(), 0);
        m.setPeers(threePeers());
        QVERIFY(!m.index(99, 0).data(PeerModel::HostNameRole).isValid());
        QVERIFY(!m.index(0, 0).data(Qt::DisplayRole).isValid());
        QCOMPARE(m.rowCount(m.index(0, 0)), 0);
    }

    // A peer object with no "ID" key parses to an empty nodeId, so a truncated
    // or degraded status really can hand the model two rows under one key.
    // The removal pass asks a set and keeps both; nothing must be left behind
    // once the shorter list has been settled.
    void dropsRowsLeftOverWhenPeersShareANodeId()
    {
        PeerModel m;
        m.setPeers({peer("", "alpha"), peer("", "bravo")});
        QCOMPARE(m.rowCount(), 2);
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        m.setPeers({peer("", "alpha")});
        QCOMPARE(m.rowCount(), 1);
        QCOMPARE(removed.count(), 1);
        QCOMPARE(m.index(0, 0).data(PeerModel::HostNameRole).toString(),
                 QStringLiteral("alpha"));
        // And the row that is left is the one the new list named, not whatever
        // happened to sit at row 0.
        QVERIFY(!rowOfHostName(m, QStringLiteral("bravo")).isValid());
    }

    void emptiesWithoutResetting()
    {
        PeerModel m;
        m.setPeers(threePeers());
        QSignalSpy reset(&m, &QAbstractItemModel::modelAboutToBeReset);
        QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
        m.setPeers({});
        QCOMPARE(m.rowCount(), 0);
        QCOMPARE(reset.count(), 0);
        // Three neighbours leave in one signal, not three.
        QCOMPARE(removed.count(), 1);
    }
};

C7_TEST_MAIN(TestPeerModel)
#include "tst_peermodel.moc"
