#include "backends/tailscale/FakeTailscaleBackend.h"

#include "testing/testmain.h"

#include <QtCore/QMetaObject>
#include <QtCore/QVariant>
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
        // Nothing short of attempting a write says whether tailscaled will
        // take one, so a backend that has not tried reads as not known to be
        // writable -- never as writable with nothing to show for it.
        QVERIFY(!ts->writable());
        QVERIFY(ts->writeError().isEmpty());
    }

    // The actions exist for QML to call, and QML calls them by NAME through
    // the meta-object. A method that lost its Q_INVOKABLE still compiles,
    // still links and is simply not there at run time, where the failure is a
    // console warning behind a click that does nothing.
    void everyActionIsCallableByName_data()
    {
        QTest::addColumn<QByteArray>("action");
        QTest::addColumn<QVariant>("argument");
        QTest::addColumn<QString>("recorded");
        QTest::newRow("connect") << QByteArray("setWantRunning") << QVariant(true)
                                 << QStringLiteral("setWantRunning(true)");
        QTest::newRow("disconnect") << QByteArray("setWantRunning") << QVariant(false)
                                    << QStringLiteral("setWantRunning(false)");
        QTest::newRow("an exit node")
                << QByteArray("setExitNode") << QVariant(QStringLiteral("nABC123CNTRL"))
                << QStringLiteral("setExitNode(nABC123CNTRL)");
        // The documented spelling of "none": an empty id, not a sentinel
        // string and not a separate action.
        QTest::newRow("no exit node") << QByteArray("setExitNode") << QVariant(QString())
                                      << QStringLiteral("setExitNode()");
        QTest::newRow("lan access")
                << QByteArray("setExitNodeAllowLANAccess") << QVariant(true)
                << QStringLiteral("setExitNodeAllowLANAccess(true)");
        QTest::newRow("accept routes") << QByteArray("setAcceptRoutes") << QVariant(false)
                                       << QStringLiteral("setAcceptRoutes(false)");
        QTest::newRow("accept dns") << QByteArray("setAcceptDns") << QVariant(true)
                                    << QStringLiteral("setAcceptDns(true)");
    }

    void everyActionIsCallableByName()
    {
        QFETCH(QByteArray, action);
        QFETCH(QVariant, argument);
        QFETCH(QString, recorded);
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        const bool called =
                argument.typeId() == QMetaType::QString
                        ? QMetaObject::invokeMethod(ts, action.constData(),
                                                    Q_ARG(QString, argument.toString()))
                        : QMetaObject::invokeMethod(ts, action.constData(),
                                                    Q_ARG(bool, argument.toBool()));
        QVERIFY2(called, action.constData());
        QCOMPARE(fake.calls(), QStringList{recorded});
    }

    // An action asks; it does not assign. Nothing on the contract moves when
    // one is called, because what the system did is the system's to report --
    // and a contract that moved its own properties would make a write that was
    // refused look exactly like one that was taken.
    void anActionChangesNothingOnTheContract()
    {
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        fake.setExitNodeId(QStringLiteral("nDEF456CNTRL"));
        QSignalSpy spy(&fake, &TailscaleBackend::exitNodeIdChanged);
        ts->setExitNode(QStringLiteral("nABC123CNTRL"));
        ts->setWantRunning(false);
        QCOMPARE(ts->exitNodeId(), QStringLiteral("nDEF456CNTRL"));
        QCOMPARE(spy.size(), 0);
        QCOMPARE(fake.calls().size(), 2);
    }

    // A refusal is ordinary -- tailscaled takes orders only from root or the
    // one user named as its operator -- so it reaches QML as state, with a
    // signal, like everything else the panel draws.
    void aRefusedWriteReachesQmlAsState()
    {
        FakeTailscaleBackend fake;
        TailscaleBackend *ts = &fake;
        QSignalSpy writable(&fake, &TailscaleBackend::writableChanged);
        QSignalSpy error(&fake, &TailscaleBackend::writeErrorChanged);
        fake.setWriteError(QStringLiteral("/localapi/v0/prefs answered HTTP/1.1 403 Forbidden"));
        QCOMPARE(error.size(), 1);
        QVERIFY(!ts->property("writable").toBool());
        QVERIFY(ts->property("writeError").toString().contains(QStringLiteral("403")));
        // And the other way: a write that is taken says so, so a panel can
        // tell "refused" from "not tried yet" by the error beside it.
        fake.setWritable(true);
        fake.setWriteError(QString());
        QCOMPARE(writable.size(), 1);
        QVERIFY(ts->property("writable").toBool());
        QVERIFY(ts->writeError().isEmpty());
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
