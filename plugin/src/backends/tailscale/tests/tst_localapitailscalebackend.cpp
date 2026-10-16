#include "backends/tailscale/LocalApiTailscaleBackend.h"

#include "tailscale/StatusParser.h"
#include "tailscale/Types.h"

#include "testing/fakesocketserver.h"
#include "testing/testmain.h"

#include <QtCore/QByteArray>
#include <QtCore/QFile>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QJsonValue>
#include <QtCore/QList>
#include <QtCore/QMetaObject>
#include <QtCore/QVariant>
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

// serveFixture's watch answers plain 200, so a pushed line is a notification.
// This one answers chunked, which makes the stream endable on demand: pushing
// a final chunk closes it the way tailscaled going away does, leaving the test
// in charge of *when* an established watch drops.
void serveEndableWatch(FakeSocketServer &server, const char *statusFixture)
{
    server.onRequest(
            [statusFixture](const QByteArray &request) -> QByteArray {
                if (request.contains("/localapi/v0/watch-ipn-bus"))
                    return QByteArrayLiteral("HTTP/1.1 200 OK\r\n"
                                             "Transfer-Encoding: chunked\r\n\r\n");
                if (request.contains("/localapi/v0/suggest-exit-node"))
                    return measured(fixture("suggest-exit-node.json"));
                if (request.contains("/localapi/v0/prefs"))
                    return measured(fixture("prefs.json"));
                return chunked(fixture(statusFixture));
            },
            FakeSocketServer::KeepOpen, "\r\n\r\n");
}

// A tailscaled that takes writes, and whose answers the test can change under
// the backend. `prefs` is read AT THE MOMENT IT IS ASKED, which is the whole
// point: a daemon that did something other than what it was told is the case
// rule 2 is about, and it cannot be staged with a fixed reply.
struct Daemon {
    // What a PATCH is answered with. Measured against a live tailscaled
    // 1.104.1: 200 and the resulting prefs for the operator, and
    // 403 "prefs write access denied" for anyone else.
    QByteArray patchReply;
    QByteArray prefs;
    const char *statusFixture = "status-idle.json";
};

// 403 Forbidden exactly as a live tailscaled 1.104.1 refuses a write from a
// user who is not its operator -- status, body and all. This is the ORDINARY
// answer on a machine where c7shell-bootstrap has not run.
QByteArray refused()
{
    return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; "
                             "charset=utf-8\r\nContent-Length: 26\r\n\r\n"
                             "prefs write access denied\n");
}

// Routes on the METHOD before the path, because /localapi/v0/prefs is both
// the read and the write path: a handler that matched the path first would
// answer every write with the prefs body and the backend would never see a
// refusal at all.
void serveWritableDaemon(FakeSocketServer &server, const Daemon *daemon)
{
    server.onRequest(
            [daemon](const QByteArray &request) -> QByteArray {
                if (request.startsWith("PATCH"))
                    return daemon->patchReply;
                if (request.contains("/localapi/v0/watch-ipn-bus"))
                    return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                if (request.contains("/localapi/v0/suggest-exit-node"))
                    return measured(fixture("suggest-exit-node.json"));
                if (request.contains("/localapi/v0/prefs"))
                    return measured(daemon->prefs);
                if (request.contains("/localapi/v0/status"))
                    return chunked(fixture(daemon->statusFixture));
                return QByteArrayLiteral("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
            },
            FakeSocketServer::KeepOpen, "\r\n\r\n");
}

// Every PATCH the fake received, in order, as it arrived.
QByteArrayList writeRequests(const FakeSocketServer &server)
{
    QByteArrayList patches;
    for (const QByteArray &request : server.requests()) {
        if (request.startsWith("PATCH"))
            patches.append(request);
    }
    return patches;
}

// Their bodies, parsed. The request line is a separate assertion where it
// matters, so a body that is right on a request that went somewhere else
// fails on the line rather than on a count that never arrives.
QList<QJsonObject> writes(const FakeSocketServer &server)
{
    QList<QJsonObject> bodies;
    for (const QByteArray &request : writeRequests(server)) {
        const qsizetype at = request.indexOf("\r\n\r\n");
        bodies.append(QJsonDocument::fromJson(request.mid(at + 4)).object());
    }
    return bodies;
}

// The capture's /prefs with ExitNodeID set to `id` -- a selection tailscaled
// has taken but whose ExitNodeStatus the status does not yet carry, which is
// the window this module exists to be honest about and cannot be captured
// because it lasts moments.
QByteArray prefsSelecting(const QString &id)
{
    QJsonObject prefs = QJsonDocument::fromJson(fixture("prefs.json")).object();
    prefs.insert(QLatin1String("ExitNodeID"), id);
    return QJsonDocument(prefs).toJson(QJsonDocument::Compact);
}

// The capture with its BackendState replaced: tailscaled up and reporting
// something other than Running, which is a state the panel has words for and
// is perfectly usable.
QByteArray statusInState(const QByteArray &json, const QString &backendState)
{
    QJsonObject root = QJsonDocument::fromJson(json).object();
    root.insert(QLatin1String("BackendState"), backendState);
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

// The capture with its whole Peer section taken out: a 200 that parses, says
// Running, and does not describe the tailnet at all.
QByteArray withoutThePeerSection(const QByteArray &json)
{
    QJsonObject root = QJsonDocument::fromJson(json).object();
    root.remove(QLatin1String("Peer"));
    return QJsonDocument(root).toJson(QJsonDocument::Compact);
}

// A tailnet that really has no other devices: an empty Peer OBJECT, which is
// a description of the tailnet, unlike an absent or null one.
const QByteArray kEmptyTailnet =
        QByteArrayLiteral("{\"BackendState\":\"Running\",\"Peer\":{}}");

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

// That peer's tailnet address, read out of the same capture. The other thing
// tailscaled will accept in a prefs write where a node id belongs, and the
// one that silently selects nothing.
QString ip4Of(const char *statusFixture, const QString &hostName)
{
    const auto status = StatusParser::parse(fixture(statusFixture));
    if (!status)
        return {};
    for (const Peer &peer : status->peers) {
        if (peer.hostName == hostName)
            return peer.ip4;
    }
    return {};
}

// The name the panel puts on that peer, read out of the capture by the same
// rule the parser uses. A literal would have been "gamma" until Task 1 moved
// naming onto the DNS label, where that peer answers to host-1.
QString displayNameOf(const char *statusFixture, const QString &hostName)
{
    const auto status = StatusParser::parse(fixture(statusFixture));
    if (!status)
        return {};
    for (const Peer &peer : status->peers) {
        if (peer.hostName == hostName)
            return peer.displayName;
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
        QCOMPARE(b.selfName(), QStringLiteral("host-6"));
        QCOMPARE(b.selfIp4(), QStringLiteral("100.115.228.122"));
        // The contract strips the root dot tailscaled qualifies Self with.
        QCOMPARE(b.selfDnsName(), QStringLiteral("host-6.example-tailnet.ts.net"));
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
        // The id as well as the name: a view joins the check mark on the id,
        // because hostnames repeat on a tailnet.
        QCOMPARE(b.exitNodeId(),
                 nodeIdOf("status-exitnode.json", QStringLiteral("pentest-exit-node")));
    }

    // The window this module exists to be honest about. /prefs already names
    // the exit node, /status has not resolved an ExitNodeStatus for it yet --
    // absent on some builds, null on others -- and during exactly that window
    // egress is most likely to be on the floor. Read from the status alone it
    // is "no exit node selected": a plain healthy globe.
    void failsClosedWhenPrefsSelectsAnExitNodeTheStatusHasNotResolved()
    {
        const QString id = nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node"));
        QVERIFY(!id.isEmpty());
        FakeSocketServer server(socketPath());
        server.onRequest(
                [id](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(prefsSelecting(id));
                    // status-idle.json carries no ExitNodeStatus at all.
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QVERIFY2(b.exitNodeActive(),
                 "an exit node tailscaled has selected read as no exit node at all");
        QVERIFY2(!b.exitNodeOnline(), "an unresolved exit node read as one that answers");
        QVERIFY2(b.exitNodeBlocked(),
                 "a selected exit node with no resolvable status drew the healthy globe");
        QCOMPARE(b.exitNodeId(), id);
        // Named off the peer list, as the resolved case is: the panel says
        // which machine to clear, not which node id.
        QCOMPARE(b.exitNodeName(), QStringLiteral("pentest-exit-node"));
    }

    // And the selection being CLEARED is published from the same pair. /prefs
    // is re-read on every pass for this reason: an ExitNodeID read once on
    // connect would keep the block up long after egress was unrouted again.
    void clearsTheBlockWhenPrefsStopsSelectingAnExitNode()
    {
        const QString id = nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node"));
        FakeSocketServer server(socketPath());
        auto selecting = std::make_shared<bool>(true);
        server.onRequest(
                [id, selecting](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(*selecting ? prefsSelecting(id) : fixture("prefs.json"));
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_VERIFY(b.exitNodeBlocked());
        QTRY_COMPARE(server.clientCount(), 1);
        *selecting = false;
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_VERIFY(!b.exitNodeActive());
        QVERIFY(!b.exitNodeBlocked());
        QVERIFY(b.exitNodeId().isEmpty());
        QVERIFY(b.exitNodeName().isEmpty());
    }

    // A pass that fails leaves no half of itself behind, and a straggler from
    // it is not half of the pass that comes after. The sequence is specific:
    // /status fails, closing the pass while the /prefs read beside it is still
    // out; that late /prefs reply then arrives; and a notification starts a
    // new pass before the retry fires. The straggler has to be told apart from
    // the new pass's own /prefs, and only the token it was issued with can do
    // that -- "is a pass open?" answers yes in both cases. Paired wrongly, the
    // panel names an exit node selected at one moment against a status read at
    // another, which is the fail-closed path reading from two moments at once.
    void dropsAHalfFinishedPassWhenTheConnectionIsLost()
    {
        const QString first = nodeIdOf("status-idle.json", QStringLiteral("alpha"));
        const QString stale = nodeIdOf("status-idle.json", QStringLiteral("beta"));
        const QString current = nodeIdOf("status-idle.json", QStringLiteral("gamma"));
        QVERIFY(!first.isEmpty() && !stale.isEmpty() && !current.isEmpty());
        QVERIFY(first != stale && stale != current);

        FakeSocketServer server(socketPath());
        auto selected = std::make_shared<QString>(first);
        auto statusFails = std::make_shared<bool>(false);
        server.onRequest(
                [selected, statusFails](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(prefsSelecting(*selected));
                    if (*statusFails)
                        return QByteArrayLiteral(
                                "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n");
                    // No ExitNodeStatus, so the id on the panel is the one
                    // /prefs supplied and the pairing is what is being read.
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // A retry base no test will wait out: the question is what the pass
        // after the failure pairs, not when open() eventually repairs it.
        LocalApiTailscaleBackend b(socketPath(), 20000);
        QTRY_COMPARE(b.exitNodeId(), first);
        QTRY_COMPARE(server.clientCount(), 1);

        // The pass that fails. Its /prefs reply is held, so it lands AFTER
        // the status failure rather than racing it.
        server.holdNext("/localapi/v0/prefs ");
        *statusFails = true;
        *selected = stale;
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(b.state(), TailscaleBackend::State::NoState);
        QTRY_COMPARE(server.heldCount(), 1);
        QCOMPARE(server.completeHeld(measured(prefsSelecting(stale))), 1);

        // The next pass, before the retry fires. Both of its reads answer.
        // No wait between the two: the straggler and this notification race
        // deliberately, because that race is the defect. A qWait here would
        // let the straggler land between passes, where even a boolean turns
        // it away, and the test would pass against the bug.
        *statusFails = false;
        *selected = current;
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QCOMPARE(b.exitNodeId(), current);
        QCOMPARE(b.exitNodeName(), displayNameOf("status-idle.json", QStringLiteral("gamma")));
    }

    // /suggest-exit-node is an optional feature endpoint, not a health probe,
    // and counting it as one left a machine never finishing a connection at
    // all: nothing established, the settle timer never armed, Running/NoState
    // flapping at the retry cap forever -- with the slot and the panel both
    // gated on state, so blank or absent nearly all the time.
    //
    // The rows are the two ways it is measured to fail on a daemon that is
    // perfectly healthy. Neither is an unusual tailnet.
    void connectsThroughASuggestionThatFails_data()
    {
        QTest::addColumn<QByteArray>("suggestReply");
        QTest::addColumn<QByteArray>("backendState");
        QTest::addColumn<int>("expected");

        // A tailnet with no exit node to suggest has nothing to answer with.
        QTest::newRow("404, no exit nodes on the tailnet")
                << QByteArrayLiteral("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                << QByteArrayLiteral("Running") << int(TailscaleBackend::State::Running);
        // Measured on a live daemon: "no preferred DERP, try again later" is
        // what it answers before DERP is resolved, which is every cold boot
        // and every network change -- a transient the daemon explicitly asks
        // to be retried, on a machine where nothing at all is wrong.
        QTest::newRow("500, DERP not resolved yet")
                << (QByteArrayLiteral("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 46"
                                      "\r\n\r\n")
                    + QByteArrayLiteral("{\"error\":\"no preferred DERP, try again later\"}"))
                << QByteArrayLiteral("Running") << int(TailscaleBackend::State::Running);
        // The same 500, on a daemon that is up and logged out. /status and
        // /prefs both answer, NeedsLogin is a state the panel has words for,
        // and the whole slot used to be absent from the bar for it.
        QTest::newRow("500, tailscaled up and logged out")
                << (QByteArrayLiteral("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 46"
                                      "\r\n\r\n")
                    + QByteArrayLiteral("{\"error\":\"no preferred DERP, try again later\"}"))
                << QByteArrayLiteral("NeedsLogin") << int(TailscaleBackend::State::NeedsLogin);
    }

    void connectsThroughASuggestionThatFails()
    {
        QFETCH(QByteArray, suggestReply);
        QFETCH(QByteArray, backendState);
        QFETCH(int, expected);
        FakeSocketServer server(socketPath());
        server.onRequest(
                [suggestReply, backendState](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return suggestReply;
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    return chunked(statusInState(fixture("status-idle.json"),
                                                 QString::fromUtf8(backendState)));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // One millisecond of base, so a backend that treats the failure as a
        // lost connection reconnects many times inside the bounded wait below.
        LocalApiTailscaleBackend b(socketPath(), 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        QTRY_COMPARE(int(b.state()), expected);
        QVERIFY2(b.recommendedExitNodeId().isEmpty(),
                 "a suggestion that failed was published as a recommendation");
        // And it STAYS connected. Proving a negative needs a bounded wait.
        QTest::qWait(100);
        QCOMPARE(int(b.state()), expected);
        QCOMPARE(armed.count(), 0);
        QCOMPARE(requestsFor(server, "/localapi/v0/status "), 1);
    }

    // A suggestion that stops being offered is withdrawn, not kept: the
    // RECOMMENDED heading names a row, and a row nothing stands behind any
    // more is worse than no heading.
    void forgetsTheSuggestionWhenTheEndpointStopsOfferingOne()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath(), 1);
        QTRY_VERIFY(!b.recommendedExitNodeId().isEmpty());
        QTRY_COMPARE(server.clientCount(), 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return QByteArrayLiteral(
                                "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n");
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_VERIFY(b.recommendedExitNodeId().isEmpty());
        QCOMPARE(b.state(), TailscaleBackend::State::Running);
        QCOMPARE(armed.count(), 0);
    }

    // "network devices 0" and "that reply never described the tailnet" look
    // the same on the panel, and setPeers() cannot tell them apart. The rows
    // stay as the last status that DID describe it left them.
    void keepsTheDeviceListWhenAStatusDoesNotDescribeTheTailnet()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.peers()->rowCount(), 20);
        QTRY_COMPARE(server.clientCount(), 1);

        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    return chunked(withoutThePeerSection(fixture("status-idle.json")));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/status "), 2);
        // Proving a negative needs a bounded wait.
        QTest::qWait(50);
        QCOMPARE(b.peers()->rowCount(), 20);
        QCOMPARE(b.state(), TailscaleBackend::State::Running);

        // An empty Peer OBJECT is a description -- a tailnet that really has
        // no other devices -- and does clear them, or the guard above would
        // be a list that can never shrink to nothing.
        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    return chunked(kEmptyTailnet);
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(b.peers()->rowCount(), 0);
    }

    // tailscaled wedged: the socket is accepted and then answers nothing at
    // all. No readyRead, no disconnected, no errorOccurred -- so without a
    // deadline in LocalApiClient there is no terminal signal, the refresh
    // stays in flight, every later notification takes the stale branch and
    // returns, and the bar shows a snapshot that is no longer being refreshed
    // for as long as the process lives, with no retry ever armed.
    void retriesWhenTailscaledAcceptsARequestAndNeverAnswersIt()
    {
        FakeSocketServer server(socketPath());
        auto statusReads = std::make_shared<int>(0);
        server.onRequest(
                [statusReads](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return measured(fixture("prefs.json"));
                    // From the second one on: accepted, never answered.
                    if (++*statusReads >= 2)
                        return QByteArray();
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // A 150ms deadline rather than the shipped ten seconds, and a retry
        // base no test will wait out: the question is whether a hung exchange
        // ends at all, not when the reconnect after it fires.
        LocalApiTailscaleBackend b(socketPath(), 20000, LocalApiTailscaleBackend::kRetryCapMs, 150);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(*statusReads, 2);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::NoState);
        QVERIFY(armed.count() >= 1);
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
                                 "/localapi/v0/watch-ipn-bus?mask=18 "})
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
    // refuses one of the other health probes. Clearing the curve on the status
    // reply alone makes every pass attempt zero, so the reconnect runs flat at
    // the base delay forever: four sockets a pass, state flapping Running to
    // NoState and back.
    void theBackoffAdvancesWhenOnlyPartOfTheLocalApiAnswers()
    {
        FakeSocketServer server(socketPath());
        server.onRequest(
                [](const QByteArray &request) -> QByteArray {
                    if (request.contains("/localapi/v0/watch-ipn-bus"))
                        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
                    if (request.contains("/localapi/v0/suggest-exit-node"))
                        return measured(fixture("suggest-exit-node.json"));
                    if (request.contains("/localapi/v0/prefs"))
                        return QByteArrayLiteral(
                                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n");
                    return chunked(fixture("status-idle.json"));
                },
                FakeSocketServer::KeepOpen, "\r\n\r\n");
        // One millisecond of base: five attempts are 1+2+4+8+16 ms of curve.
        LocalApiTailscaleBackend b(socketPath(), 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        // At least five, deliberately not exactly five. Nothing in this test
        // stops the backend retrying, so armed.count() is a free-running
        // counter climbing 1, 2, 4, 8, 16, 32, then flat at 64ms -- and an
        // equality can only hold in the window between the fifth arm and the
        // sixth. QTRY polls on a 50ms step and its loop counts ITERATIONS
        // rather than wall clock, so one late poll steps over that window and
        // then keeps polling, for far longer than its nominal timeout, on a
        // count that can never equal five again. Measured: a 150ms stall here
        // fails the equality at 222, which is the shape the 50-run loop caught
        // at 219 -- the curve advancing correctly all along, not collapsing.
        //
        // `>=` is monotone and cannot be stepped over. What the curve actually
        // DID is then read off the recorded delays, which is the subject of
        // this test and does not depend on when it looked.
        QTRY_VERIFY(armed.count() >= 5);
        for (int attempt = 0; attempt < 5; ++attempt) {
            QCOMPARE(armed.at(attempt).first().toInt(),
                     LocalApiTailscaleBackend::retryDelayMs(attempt, 1));
        }
    }

    // The three reads succeeding is not a whole connection, and neither is a
    // watch that is merely accepted. Each pass here completes all three reads
    // *first* and only then drops an established stream, which is the ordinary
    // end of a long-lived watch -- tailscaled restarting, or being upgraded
    // underneath it. Clearing the curve on anything short of a connection that
    // has held makes every pass attempt zero, and the reconnect runs flat at
    // the base delay forever: the Critical again, through a different door.
    //
    // The reads finish before the stream drops, so nothing here is protected
    // by the order open() issues its requests in.
    void theBackoffAdvancesWhenTheWatchKeepsEndingAfterItStarts()
    {
        FakeSocketServer server(socketPath());
        serveEndableWatch(server, "status-idle.json");
        // One millisecond of base, and the shipped settle period: a stream
        // dropped the moment it is up has not held, so nothing clears the
        // curve and no test waits on the settle.
        LocalApiTailscaleBackend b(socketPath(), 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        for (int pass = 0; pass < 4; ++pass) {
            // Four requests a pass, and only the watch still connected: the
            // three reads have been answered and closed.
            QTRY_COMPARE(server.requests().size(), 4 * (pass + 1));
            QTRY_COMPARE(server.clientCount(), 1);
            server.pushChunk(QByteArrayLiteral("0\r\n\r\n")); // the stream ends
            QTRY_COMPARE(armed.count(), pass + 1);
            QCOMPARE(armed.at(pass).first().toInt(),
                     LocalApiTailscaleBackend::retryDelayMs(pass, 1));
        }
    }

    // The other half of that rule: a connection that does hold starts the
    // curve over, so a daemon that comes back after an outage is not retried
    // at the cap next time.
    void aConnectionThatHoldsClearsTheBackoff()
    {
        // Nothing listening yet, so the curve climbs first.
        LocalApiTailscaleBackend b(socketPath(), 1, 1);
        QSignalSpy armed(&b, &LocalApiTailscaleBackend::retryScheduled);
        QTRY_VERIFY(armed.count() >= 3);

        FakeSocketServer server(socketPath());
        serveEndableWatch(server, "status-idle.json");
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        // A one-millisecond settle, so the connection counts as held almost at
        // once. Proving it has needs a bounded wait, as proving a negative
        // does -- the shape tst_localapiclient.cpp already uses.
        QTest::qWait(50);

        const int before = armed.count();
        server.pushChunk(QByteArrayLiteral("0\r\n\r\n"));
        QTRY_COMPARE(armed.count(), before + 1);
        QCOMPARE(armed.at(before).first().toInt(),
                 LocalApiTailscaleBackend::retryDelayMs(0, 1));
    }

    // tailscaled emits several notifications for one change. While a refresh
    // is out, further notifications are remembered rather than each opening
    // its own set of sockets -- and the one that was remembered is replayed
    // when the refresh lands, because the replies in flight were asked for
    // before the change and cannot be the answer to it.
    void coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath(), 20000);
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);

        // The next status read is recorded and left unanswered, which is what
        // "while a refresh is out" has to mean if the case is to be pinned
        // rather than raced for. A held client is skipped by pushLine, so the
        // notifications below reach the watch and not this half-answered read.
        server.holdNext("/localapi/v0/status ");
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        QTRY_COMPARE(server.heldCount(), 1);
        const int statusReads = requestsFor(server, "/localapi/v0/status ");
        const int suggestReads = requestsFor(server, "/localapi/v0/suggest-exit-node ");
        QCOMPARE(statusReads, 2);

        for (int i = 0; i < 5; ++i)
            server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
        // Proving a negative needs a bounded wait; this is the shape
        // tst_localapiclient.cpp already uses for it.
        QTest::qWait(50);
        QCOMPARE(requestsFor(server, "/localapi/v0/status "), statusReads);
        QCOMPARE(requestsFor(server, "/localapi/v0/suggest-exit-node "), suggestReads);
        QCOMPARE(b.state(), TailscaleBackend::State::Running);

        // Remembered, not dropped. Answering the held read has to send one
        // more pass, because the five notifications above were answered by
        // nothing -- and without the replay the change that provoked them is
        // lost until something else happens on the bus, which on a quiet
        // tailnet is hours. Deleting the replay leaves every assertion above
        // still passing, which is why the completion is part of this test.
        QCOMPARE(server.completeHeld(chunked(fixture("status-idle.json"))), 1);
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/status "), statusReads + 1);
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/suggest-exit-node "), suggestReads + 1);
        QCOMPARE(b.state(), TailscaleBackend::State::Running);
    }

    // Dropping the engine bit from our own mask is necessary and not
    // sufficient: tailscaled broadcasts an ongoing notification to every
    // watcher whatever mask it asked for, so any other process on the machine
    // watching with mask=1 puts the 2s byte-counter drumbeat on this stream
    // too. Measured on a live 1.104.1 -- a mask=2 watcher sat silent for 20s,
    // then took six Engine notifications the moment a mask=1 watcher joined.
    //
    // Re-reading a 28KB status for counters nothing displays is the polling
    // docs/architecture.md keeps backends away from, and coalescing does not
    // help: each one lands after the last refresh finished.
    void aNotificationCarryingNothingThisModuleReadsDoesNotRefresh()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        QCOMPARE(requestsFor(server, "/localapi/v0/status "), 1);

        // Verbatim from the live bus, byte counts and all.
        server.pushLine(QByteArrayLiteral(
                "{\"Version\":\"1.104.1\",\"ErrMessage\":null,\"LoginFinished\":null,"
                "\"State\":null,\"Prefs\":null,\"Engine\":{\"RBytes\":17844928,"
                "\"WBytes\":683992,\"NumLive\":1,\"LiveDERPs\":1},"
                "\"BrowseToURL\":null,\"DriveShares\":null}"));
        // Proving a negative needs a bounded wait.
        QTest::qWait(50);
        QCOMPARE(requestsFor(server, "/localapi/v0/status "), 1);

        // Skipped, not lost: a notification that does carry something still
        // re-reads, so the filter cannot quietly deafen the module.
        server.pushLine(QByteArrayLiteral("{\"Version\":\"1.104.1\",\"State\":6}"));
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/status "), 2);
    }

    // Fails safe: a notification naming something this module does not know
    // is a reason to re-read, not a reason to ignore it.
    void refreshesOnANotificationItDoesNotRecognise()
    {
        FakeSocketServer server(socketPath());
        serveFixture(server, "status-idle.json");
        LocalApiTailscaleBackend b(socketPath());
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QTRY_COMPARE(server.clientCount(), 1);
        server.pushLine(QByteArrayLiteral(
                "{\"Version\":\"1.104.1\",\"Engine\":null,\"SomethingNewIn2027\":{}}"));
        QTRY_COMPARE(requestsFor(server, "/localapi/v0/status "), 2);
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

    // ---- Writes ----

    // Each action is one pref, written with the `...Set` sibling beside it.
    // MaskedPrefs is a prefs object plus a boolean per field naming it as one
    // the caller means: tailscaled drops a field whose sibling is absent,
    // SILENTLY AND WITH A 200, which is a control that reports success and
    // changes nothing. The exact-object comparison is the point -- a body
    // carrying anything else is a body this module did not mean to send.
    void writesThePrefAndItsSetSibling_data()
    {
        QTest::addColumn<QByteArray>("action");
        QTest::addColumn<QVariant>("argument");
        QTest::addColumn<QString>("field");
        QTest::newRow("connect") << QByteArray("setWantRunning") << QVariant(true)
                                 << QStringLiteral("WantRunning");
        QTest::newRow("disconnect") << QByteArray("setWantRunning") << QVariant(false)
                                    << QStringLiteral("WantRunning");
        QTest::newRow("local network access")
                << QByteArray("setExitNodeAllowLANAccess") << QVariant(true)
                << QStringLiteral("ExitNodeAllowLANAccess");
        // RouteAll and CorpDNS, not the names the panel uses for them: the
        // wire names are tailscaled's and nothing else accepts them.
        QTest::newRow("accept routes") << QByteArray("setAcceptRoutes") << QVariant(true)
                                       << QStringLiteral("RouteAll");
        QTest::newRow("accept dns") << QByteArray("setAcceptDns") << QVariant(false)
                                    << QStringLiteral("CorpDNS");
        QTest::newRow("an exit node")
                << QByteArray("setExitNode")
                << QVariant(nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node")))
                << QStringLiteral("ExitNodeID");
        // "none" is an empty id, and it still carries the sibling: without it
        // the clear is dropped and the exit node stays selected.
        QTest::newRow("no exit node") << QByteArray("setExitNode") << QVariant(QString())
                                      << QStringLiteral("ExitNodeID");
    }

    void writesThePrefAndItsSetSibling()
    {
        QFETCH(QByteArray, action);
        QFETCH(QVariant, argument);
        QFETCH(QString, field);
        Daemon daemon{measured(fixture("prefs-patched.json")), fixture("prefs.json")};
        FakeSocketServer server(socketPath());
        serveWritableDaemon(server, &daemon);
        LocalApiTailscaleBackend b(socketPath());
        TailscaleBackend *ts = &b;
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);

        const bool called = argument.typeId() == QMetaType::QString
                ? QMetaObject::invokeMethod(ts, action.constData(),
                                            Q_ARG(QString, argument.toString()))
                : QMetaObject::invokeMethod(ts, action.constData(),
                                            Q_ARG(bool, argument.toBool()));
        QVERIFY2(called, action.constData());

        QTRY_COMPARE(writes(server).size(), 1);
        QVERIFY2(writeRequests(server).first().startsWith(
                         "PATCH /localapi/v0/prefs HTTP/1.1\r\n"),
                 writeRequests(server).first().constData());
        QJsonObject expected;
        expected.insert(field, QJsonValue::fromVariant(argument));
        expected.insert(field + QStringLiteral("Set"), true);
        QCOMPARE(writes(server).first(), expected);
    }

    // The ordinary failure on a machine where nobody has named this user as
    // tailscaled's operator, which is every machine until c7shell-bootstrap
    // has run. It must be visible: a toggle that springs back for no stated
    // reason is the thing this property exists to prevent.
    void reportsThatItCannotWriteOnA403()
    {
        Daemon daemon{refused(), fixture("prefs.json")};
        FakeSocketServer server(socketPath());
        serveWritableDaemon(server, &daemon);
        LocalApiTailscaleBackend b(socketPath());
        TailscaleBackend *ts = &b;
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QVERIFY2(ts->writable(), "a backend nothing has refused yet read as unwritable");

        QSignalSpy writable(&b, &TailscaleBackend::writableChanged);
        QSignalSpy error(&b, &TailscaleBackend::writeErrorChanged);
        ts->setAcceptRoutes(true);
        QTRY_VERIFY2(!ts->writeError().isEmpty(), "a refused write said nothing at all");
        QVERIFY2(ts->writeError().contains(QStringLiteral("403")), qPrintable(ts->writeError()));
        QCOMPARE(error.size(), 1);
        QVERIFY2(!ts->writable(), "a refused write left the panel saying writes work");
        QCOMPARE(writable.size(), 1);

        // A PERMISSION SETTING IS NOT A DAEMON THAT HAS GONE. Every other
        // failure on this socket routes to lostTailscaled(), which publishes
        // NoState, blanks the panel and starts the reconnect curve -- and a
        // panel that has just disappeared cannot explain why the toggle moved
        // back. This is what the separate write client is for.
        QCOMPARE(b.state(), TailscaleBackend::State::Running);
        QCOMPARE(b.peers()->rowCount(), 20);

        // And it RECOVERS: a machine bootstrapped while the panel is open
        // stops explaining itself at the next write, so the flag follows the
        // last attempt in both directions rather than latching on the first
        // refusal.
        daemon.patchReply = measured(fixture("prefs-patched.json"));
        ts->setAcceptRoutes(true);
        QTRY_VERIFY(ts->writable());
        QCOMPARE(writable.size(), 2);
        QVERIFY2(ts->writeError().isEmpty(), qPrintable(ts->writeError()));
    }

    // THE BUS IS THE AUTHORITY. A write is a request; what this module
    // publishes is what tailscaled then says, even when that is not what was
    // asked for -- another process selecting a different exit node a moment
    // later is the ordinary way that happens, and the panel has no standing to
    // argue with it. Publishing the click instead makes a refused write and an
    // accepted one look identical.
    void letsTheBusOverruleAnOptimisticWrite()
    {
        const QString chosen =
                nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node"));
        const QString imposed = nodeIdOf("status-idle.json", QStringLiteral("ip-172-31-0-10"));
        QVERIFY(!chosen.isEmpty());
        QVERIFY(!imposed.isEmpty());
        QVERIFY(chosen != imposed);

        Daemon daemon{measured(fixture("prefs-patched.json")), fixture("prefs.json")};
        FakeSocketServer server(socketPath());
        serveWritableDaemon(server, &daemon);
        LocalApiTailscaleBackend b(socketPath());
        TailscaleBackend *ts = &b;
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
        QVERIFY(ts->exitNodeId().isEmpty());

        ts->setExitNode(chosen);
        // Nothing has moved yet, and nothing may: no event loop has run
        // between the call and this line, so the request cannot even have
        // left the process. A backend that published here would be reporting
        // its own intention as tailscaled's state.
        QCOMPARE(ts->exitNodeId(), QString());
        QVERIFY(!ts->exitNodeActive());

        // tailscaled took the write and ended up somewhere else.
        daemon.prefs = prefsSelecting(imposed);
        QTRY_COMPARE(writes(server).size(), 1);
        // The write has gone out and been answered, and STILL nothing has
        // moved. Proving that negative needs a bounded wait, as it does
        // everywhere else here; writable() cannot serve as the probe, because
        // it starts true and says nothing about a write having round-tripped.
        QTest::qWait(50);
        QVERIFY2(ts->writeError().isEmpty(), qPrintable(ts->writeError()));
        QCOMPARE(ts->exitNodeId(), QString());
        server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));

        QTRY_COMPARE(ts->exitNodeId(), imposed);
        QVERIFY2(ts->exitNodeId() != chosen,
                 "the panel published what was clicked instead of what tailscaled reported");
    }

    // /prefs carries ExitNodeID and ExitNodeIP side by side. A selection
    // written into the address is accepted without complaint and selects
    // nothing, and tailscaled refuses a mask that names both at once -- so the
    // field that goes on the wire is pinned here rather than left to read the
    // same either way.
    void selectsAnExitNodeByIdNotByIp()
    {
        const QString id = nodeIdOf("status-idle.json", QStringLiteral("pentest-exit-node"));
        const QString ip4 = ip4Of("status-idle.json", QStringLiteral("pentest-exit-node"));
        QVERIFY(!id.isEmpty());
        QVERIFY(!ip4.isEmpty());

        Daemon daemon{measured(fixture("prefs-patched.json")), fixture("prefs.json")};
        FakeSocketServer server(socketPath());
        serveWritableDaemon(server, &daemon);
        LocalApiTailscaleBackend b(socketPath());
        TailscaleBackend *ts = &b;
        QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);

        ts->setExitNode(id);
        QTRY_COMPARE(writes(server).size(), 1);
        const QJsonObject body = writes(server).first();
        QCOMPARE(body.value(QLatin1String("ExitNodeID")).toString(), id);
        QVERIFY(body.value(QLatin1String("ExitNodeIDSet")).toBool());
        QVERIFY2(!body.contains(QLatin1String("ExitNodeIP")), "the write named an address too");
        QVERIFY2(!body.contains(QLatin1String("ExitNodeIPSet")), "the write named an address too");
        // What reached the wire is the id, not the peer's address under
        // another name.
        QVERIFY2(!QJsonDocument(body).toJson(QJsonDocument::Compact).contains(ip4.toUtf8()),
                 "the exit node's tailnet address went out in the prefs write");
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
