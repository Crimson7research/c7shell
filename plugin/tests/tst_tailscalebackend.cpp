#include "backends/tailscale/FakeTailscaleBackend.h"

#include "testing/testmain.h"

#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

// What the contract itself does, rather than what any one backend does. Every
// case here is driven through a TailscaleBackend * holding a
// FakeTailscaleBackend: if the UI can be satisfied by a backend that has never
// opened a socket, the contract is the thing the UI depends on -- which is the
// whole premise of plugin/src/contracts/.
class TestTailscaleBackend : public QObject {
    Q_OBJECT

private slots:
    void aFreshBackendReadsAsNothingKnownYet()
    {
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        QCOMPARE(ts->state(), TailscaleBackend::State::NoState);
        QVERIFY(ts->selfDnsName().isEmpty());
        QVERIFY(!ts->keyExpiry().isValid());
        QVERIFY(!ts->exitNodeActive());
        QVERIFY(!ts->exitNodeBlocked());
        QCOMPARE(ts->issueCount(), 0);
        QVERIFY(ts->peers());
        QVERIFY(ts->exitNodes());
        QVERIFY(ts->recommendedExitNodeId().isEmpty());
    }

    // tailscaled qualifies Self's name with the root dot and the parser strips
    // it from peers, so the two would reach QML spelled differently. The
    // contract decides, and a backend storing the raw name cannot opt out.
    void selfDnsNameLosesTheRootDotWhateverTheBackendStored()
    {
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        fake.setRawSelfDnsName(QStringLiteral("laptop.example-tailnet.ts.net."));
        QCOMPARE(ts->selfDnsName(), QStringLiteral("laptop.example-tailnet.ts.net"));
        // Already stripped, and a name that is nothing but the root dot: both
        // leave at most one dot's worth of difference behind.
        fake.setRawSelfDnsName(QStringLiteral("laptop.example-tailnet.ts.net"));
        QCOMPARE(ts->selfDnsName(), QStringLiteral("laptop.example-tailnet.ts.net"));
        fake.setRawSelfDnsName(QStringLiteral("."));
        QCOMPARE(ts->selfDnsName(), QString());
    }

    void exitNodeBlockedIsFailClosed_data()
    {
        QTest::addColumn<bool>("active");
        QTest::addColumn<bool>("online");
        QTest::addColumn<bool>("blocked");
        QTest::newRow("no exit node") << false << false << false;
        QTest::newRow("no exit node, stale online") << false << true << false;
        QTest::newRow("exit node reachable") << true << true << false;
        QTest::newRow("exit node unreachable") << true << false << true;
    }

    void exitNodeBlockedIsFailClosed()
    {
        QFETCH(bool, active);
        QFETCH(bool, online);
        QFETCH(bool, blocked);
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        fake.setExitNodeActive(active);
        fake.setExitNodeOnline(online);
        QCOMPARE(ts->exitNodeBlocked(), blocked);
        QCOMPARE(ts->property("exitNodeBlocked").toBool(), blocked);
    }

    // The flag a UI leans on hardest is the one no backend emits, so prove
    // the contract emits it off both of its inputs.
    void exitNodeBlockedAnnouncesItselfOnEitherInput()
    {
        FakeTailscaleBackend fake;
        QSignalSpy spy(&fake, &TailscaleBackend::exitNodeBlockedChanged);
        fake.setExitNodeActive(true);
        QVERIFY(!spy.isEmpty());
        spy.clear();
        fake.setExitNodeOnline(true);
        QVERIFY(!spy.isEmpty());
        spy.clear();
        // The transition that matters: a working exit node drops off the
        // tailnet, and only Online moved.
        fake.setExitNodeOnline(false);
        QVERIFY(!spy.isEmpty());
        QVERIFY(fake.exitNodeBlocked());
    }

    // A property derived from exactly one other shares its signal, so there is
    // no second signal to leave unemitted.
    void issueCountRidesTheIssuesSignal()
    {
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        QSignalSpy spy(&fake, &TailscaleBackend::issuesChanged);
        fake.setIssues({QStringLiteral("Tailscale is stopped"),
                        QStringLiteral("DNS is not working")});
        QCOMPARE(spy.size(), 1);
        QCOMPARE(ts->issueCount(), 2);
        QCOMPARE(ts->property("issueCount").toInt(), 2);
        fake.setIssues({});
        QCOMPARE(spy.size(), 2);
        QCOMPARE(ts->issueCount(), 0);
    }

    // Peers reach QML as a model, and exitNodes is the same model type holding
    // a different set -- the one shape a view can bind to twice.
    void bothCollectionsAreStableRowModels()
    {
        using c7::tailscale::Peer;
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        Peer laptop;
        laptop.nodeId = QStringLiteral("nABC123CNTRL");
        laptop.hostName = QStringLiteral("laptop");
        Peer relay;
        relay.nodeId = QStringLiteral("nDEF456CNTRL");
        relay.hostName = QStringLiteral("c7-exit-ams");
        relay.exitNodeOption = true;
        fake.setPeers({laptop, relay});
        fake.setExitNodes({relay});
        QCOMPARE(ts->peers()->rowCount(), 2);
        QCOMPARE(ts->exitNodes()->rowCount(), 1);
        QVERIFY(ts->peers() != ts->exitNodes());
        fake.setRecommendedExitNodeId(relay.nodeId);
        QCOMPARE(ts->recommendedExitNodeId(), relay.nodeId);
    }
};

C7_TEST_MAIN(TestTailscaleBackend)
#include "tst_tailscalebackend.moc"
