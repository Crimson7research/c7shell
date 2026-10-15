#include "backends/tailscale/LocalApiTailscaleBackend.h"

#include "tailscale/StatusParser.h"
#include "tailscale/Types.h"

#include "testing/fakesocketserver.h"
#include "testing/testmain.h"

#include <QtCore/QByteArray>
#include <QtCore/QFile>
#include <QtCore/QStringList>
#include <QtCore/QTemporaryDir>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

#include <memory>

using c7::tailscale::Peer;
using c7::tailscale::StatusParser;
using c7::testing::FakeSocketServer;

namespace {

// A capture of what tailscaled answers, read from the source tree so the test
// does not depend on where the build directory is.
QByteArray fixture(const char *name)
{
    QFile file(QStringLiteral(C7_FIXTURE_DIR "/") + QString::fromUtf8(name));
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return file.readAll();
}

// /status arrives Transfer-Encoding: chunked on a live tailscaled 1.104.1,
// /prefs and /suggest-exit-node with a Content-Length. The fake answers each
// the way the real one does, because a backend that only ever saw one framing
// is a backend that works against a fixture and not against tailscaled.
QByteArray chunked(const QByteArray &body)
{
    return QByteArrayLiteral("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            + QByteArray::number(body.size(), 16) + "\r\n" + body + "\r\n0\r\n\r\n";
}

QByteArray measured(const QByteArray &body)
{
    return "HTTP/1.1 200 OK\r\nContent-Length: " + QByteArray::number(body.size())
            + "\r\n\r\n" + body;
}

// The backend reads three endpoints and watches a fourth, so the fake routes
// on the request path. One handler answering everything with a status body
// would hand the prefs GET 300KB of status and give the watch a response that
// ends -- neither of which tailscaled does, and both of which would let a
// backend pass here and fail on the machine it runs on.
void serveFixture(FakeSocketServer &server, const char *statusFixture)
{
    server.onRequest(
            [statusFixture](const QByteArray &request) -> QByteArray {
                if (request.contains("/localapi/v0/watch-ipn-bus"))
                    // Headers only: the stream's notifications come from
                    // pushLine, which is how tailscaled writes them.
                    return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                if (request.contains("/localapi/v0/suggest-exit-node"))
                    return measured(fixture("suggest-exit-node.json"));
                if (request.contains("/localapi/v0/prefs"))
                    return measured(fixture("prefs.json"));
                if (request.contains("/localapi/v0/status"))
                    return chunked(fixture(statusFixture));
                return QByteArrayLiteral("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            },
            FakeSocketServer::KeepOpen, "\r\n\r\n");
}

// How many of the requests the fake received name this path. The trailing
// space is part of the argument, so "/localapi/v0/status " does not also count
// a path it is a prefix of.
int requestsFor(const FakeSocketServer &server, const char *path)
{
    int seen = 0;
    for (const QByteArray &request : server.requests())
        seen += request.contains(path) ? 1 : 0;
    return seen;
}

// The node id of the peer with this hostname, read out of the same capture the
// test serves. Never written out as a literal: the redaction randomises every
// node id, so a literal is stale the moment a fixture is regenerated.
QString nodeIdOf(const char *statusFixture, const QString &hostName)
{
    const auto status = StatusParser::parse(fixture(statusFixture));
    if (!status)
        return {};
    for (const Peer &peer : status->peers) {
        if (peer.hostName == hostName)
            return peer.nodeId;
    }
    return {};
}

} // namespace

// LocalApiTailscaleBackend against a fake tailscaled: every case drives the
// real socket client, the real parser and the real models, and the only thing
// standing in for the outside world is the Unix socket on the far end.
class TestLocalApiTailscaleBackend : public QObject {
    Q_OBJECT

private slots:
    void init()
    {
        // A fresh directory per test, so no test sees another's socket -- and
        // so nothing here can reach the real /var/run/tailscale/tailscaled.sock.
        dir = std::make_unique<QTemporaryDir>();
        QVERIFY(dir->isValid());
    }

    void publishesStateAndPeersFromTheStatusReply()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(b.peers()->rowCount(), 20);
        QCOMPARE(b.selfName(), QStringLiteral("omega"));
        QCOMPARE(b.selfIp4(), QStringLiteral("100.73.10.20"));
        // The contract strips the root dot tailscaled qualifies Self with.
        QCOMPARE(b.selfDnsName(), QStringLiteral("omega.example-tailnet.ts.net"));
        QCOMPARE(b.tailnet(), QStringLiteral("example.com"));
    }

    void reportsTheBlockedStateWhenTheExitNodeIsOffline()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-exitnode-offline.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_VERIFY(b.exitNodeBlocked());
        // ExitNodeStatus carries no hostname; the label is joined off the peer
        // list, so a blocked panel names a machine and not a node id.
        QCOMPARE(b.exitNodeName(), QStringLiteral("pentest-exit-node"));
        QVERIFY(b.exitNodeActive());
        QVERIFY(!b.exitNodeOnline());
    }

    // A reachable exit node is the same fixture with one bool moved, and it
    // must not read as blocked -- otherwise the flag is a constant.
    void doesNotReportBlockedWhileTheExitNodeAnswers()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-exitnode.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_VERIFY(b.exitNodeActive());
        QVERIFY(b.exitNodeOnline());
        QVERIFY(!b.exitNodeBlocked());
    }

    void doesNotCountTheSuppressedRouteWarning()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        // The capture's only health entry is the one this machine always has.
        const auto status = StatusParser::parse(fixture("status-idle.json"));
        QVERIFY(status);
        QCOMPARE(status->health.size(), 1);
        QCOMPARE(b.issueCount(), 0);
        QVERIFY(b.issues().isEmpty());
    }

    // Suppression is a named policy, not a blanket silence: anything else
    // tailscaled complains about still reaches the panel.
    void countsEveryOtherHealthWarning()
    {
        auto status = StatusParser::parse(fixture("status-idle.json"));
        QVERIFY(status);
        QStringList health = status->health;
        health.append(QStringLiteral("DNS is not working"));
        QCOMPARE(LocalApiTailscaleBackend::reportableHealth(health),
                 QStringList{QStringLiteral("DNS is not working")});
        QVERIFY(!LocalApiTailscaleBackend::suppressedHealth().isEmpty());
    }

    void settlesInNoStateWhenTailscaledIsAbsent()
    {
        // No server at the path at all: nothing answers, nothing hangs, and
        // the backend reads as a machine that has not reported in.
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::NoState);
        QCOMPARE(b.peers()->rowCount(), 0);
        QVERIFY(!b.exitNodeActive());
    }

    void republishesOnAWatchEvent()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.exitNodeActive(), false);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        // Only the watch is still connected once the three opening gets have
        // been answered, so the notification cannot land in a get's body.
        QTRY_COMPARE(server.clientCount(), 1);
        serveFixture(server, "status-exitnode.json");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(b.exitNodeActive(), true);
        QCOMPARE(b.exitNodeName(), QStringLiteral("pentest-exit-node"));
    }

    void publishesOnlyExitNodeCapablePeersAsExitNodes()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QCOMPARE(b.exitNodes()->rowCount(), 2);
        QVERIFY(b.exitNodes() != b.peers());
        const QString expected = nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node"));
        QVERIFY(!expected.isEmpty());
        QTRY_COMPARE(b.recommendedExitNodeId(), expected);
    }

    // The contract chains exitNodeActiveChanged and exitNodeOnlineChanged onto
    // exitNodeBlockedChanged synchronously, so a backend that emits before the
    // sibling member has moved hands QML a blocked flag computed from half of
    // one status and half of the next. Idle to a reachable exit node is the
    // transition that exposes it: store active first and emit, and the still
    // stale online reads false, which is a false alarm on the one flag the
    // panel leads with.
    void everyExitNodeFieldIsStoredBeforeBlockedIsAnnounced()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        bool everBlocked = false;
        connect(&b, &TailscaleBackend::exitNodeBlockedChanged, &b,
                [&b, &everBlocked] { everBlocked = everBlocked || b.exitNodeBlocked(); });
        serveFixture(server, "status-exitnode.json");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_VERIFY(b.exitNodeActive());
        QVERIFY(!b.exitNodeBlocked());
        QVERIFY2(!everBlocked, "exitNodeBlocked was announced true while a reachable exit node "
                               "was being published");
    }

    // tailscaled restarting takes the socket with it. The backend says so, and
    // comes back on its own when tailscaled does.
    void returnsToNoStateAndReconnectsWhenTailscaledRestarts()
    {
        auto server = std::make_unique<FakeSocketServer>(socketPath());
        QVERIFY2(server->isListening(), qPrintable(server->error()));
        serveFixture(*server, "status-idle.json");
        // One millisecond of backoff rather than the shipped half-second: a
        // test may not sleep out the real curve (docs/architecture.md:204).
        LocalApiTailscaleBackend b(socketPath(), 1);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);

        server.reset();
        QTRY_COMPARE(b.state(), TailscaleBackend::State::NoState);

        server = std::make_unique<FakeSocketServer>(socketPath());
        QVERIFY2(server->isListening(), qPrintable(server->error()));
        serveFixture(*server, "status-exitnode.json");
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_VERIFY(b.exitNodeActive());
    }

    // A status reply that is not a status is not a reason to publish Running
    // off whatever defaults the parser filled in.
    void refusesAStatusThatCarriesNoBackendState()
    {
        FakeSocketServer server(socketPath());
        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/status"))
                        return chunked(QByteArrayLiteral("{}"));
                    return measured(QByteArrayLiteral("{}"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(server.requests().size(), 4);
        QCOMPARE(b.state(), TailscaleBackend::State::NoState);
    }

    // Each of the three endpoints is read once on connect, and the fourth is
    // the stream -- nothing polls.
    void readsEachEndpointOnceAndThenWatches()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.requests().size(), 4);
        for (const char *path : {"/localapi/v0/status ", "/localapi/v0/prefs ",
                                 "/localapi/v0/suggest-exit-node ",
                                 "/localapi/v0/watch-ipn-bus?mask=1 "})
            QCOMPARE(requestsFor(server, path), 1);
        // Nothing polls: with no notification on the bus, nothing is re-read.
        QTest::qWait(100);
        QCOMPARE(server.requests().size(), 4);
    }

    // The curve, checked as arithmetic rather than waited out: the cap is
    // thirty seconds and no test may spend thirty seconds reaching it.
    void theRetryCurveDoublesAndCapsAtThirtySeconds()
    {
        using B = LocalApiTailscaleBackend;
        QCOMPARE(B::retryDelayMs(0, B::kRetryBaseMs), 500);
        QCOMPARE(B::retryDelayMs(1, B::kRetryBaseMs), 1000);
        QCOMPARE(B::retryDelayMs(2, B::kRetryBaseMs), 2000);
        QCOMPARE(B::retryDelayMs(5, B::kRetryBaseMs), 16000);
        // 500 << 6 is 32000, over the cap.
        QCOMPARE(B::retryDelayMs(6, B::kRetryBaseMs), B::kRetryCapMs);
        QCOMPARE(B::retryDelayMs(60, B::kRetryBaseMs), B::kRetryCapMs);
    }

    // One lost connection reports itself up to five times -- three refused
    // reads, plus the watch's failed and then watchEnded -- and must arm one
    // reconnect, not five.
    void oneLostConnectionArmsOneRetry()
    {
        FakeSocketServer server(socketPath());
        server.onRequest(
                [](const QByteArray &) {
                    return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // A base no test will wait out: the question here is how many
        // reconnects one failure arms, not when they fire.
        LocalApiTailscaleBackend b(socketPath(), 20000);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        QTRY_COMPARE(server.requests().size(), 4);
        // Every socket has been failed and dropped, so every ending this
        // attempt will ever report has been reported.
        QTRY_COMPARE(server.clientCount(), 0);
        QCOMPARE(armed.count(), 1);
        QCOMPARE(armed.first().first().toInt(),
                 LocalApiTailscaleBackend::retryDelayMs(0, 20000));
    }

    // The backoff has to advance on a local API that answers /status and
    // refuses something else -- a tailnet with no exit node to suggest is the
    // live case. Clearing the curve on the status reply alone makes every pass
    // attempt zero, so the reconnect runs flat at the base delay forever:
    // four sockets a pass, state flapping Running to NoState and back.
    void theBackoffAdvancesWhenOnlyPartOfTheLocalApiAnswers()
    {
        FakeSocketServer server(socketPath());
        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return QByteArrayLiteral(
                                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // One millisecond of base: five attempts are 1+2+4+8+16 ms of curve.
        LocalApiTailscaleBackend b(socketPath(), 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        QTRY_COMPARE(armed.count(), 5);
        for (int attempt = 0; attempt < 5; ++attempt) {
            QCOMPARE(armed.at(attempt).first().toInt(),
                     LocalApiTailscaleBackend::retryDelayMs(attempt, 1));
        }
    }

    // tailscaled emits several notifications for one change. While a refresh
    // is out, further notifications are remembered rather than each opening
    // its own pair of sockets.
    void coalescesNotificationsArrivingWhileARefreshIsOut()
    {
        FakeSocketServer server(socketPath());
        auto statusReads = std::make_shared<int>(0);
        server.onRequest(
                [statusReads](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    // The second status read gets its headers and nothing
                    // else, so it stays in flight for the rest of the test --
                    // which is what "while a refresh is out" has to mean if
                    // the case is to be pinned rather than raced for.
                    if (++*statusReads == 2) {
                        return QByteArrayLiteral(
                                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
                    }
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiTailscaleBackend b(socketPath(), 20000);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(*statusReads, 2);
        const int suggestReads = requestsFor(server, "/localapi/v0/suggest-exit-node ");

        for (int i = 0; i < 5; ++i)
            server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        // Proving a negative needs a bounded wait; this is the shape
        // tst_localapiclient.cpp already uses for it.
        QTest::qWait(50);
        QCOMPARE(*statusReads, 2);
        QCOMPARE(requestsFor(server, "/localapi/v0/suggest-exit-node "), suggestReads);
    }

    // The suggestion names a row of exitNodes, so reading it only on connect
    // leaves a published id pointing at a row that is no longer there.
    void rereadsTheSuggestionOnANotification()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        QCOMPARE(requestsFor(server, "/localapi/v0/suggest-exit-node "), 1);
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/suggest-exit-node "), 2);
    }

private:
    QString socketPath() const
    {
        return dir->filePath(QStringLiteral("tailscale/tailscaled.sock"));
    }

    std::unique_ptr<QTemporaryDir> dir;
};

C7_TEST_MAIN(TestLocalApiTailscaleBackend)
#include "tst_localapitailscalebackend.moc"
