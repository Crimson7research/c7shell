#include "tailscale/LocalApiClient.h"

#include "testing/fakesocketserver.h"
#include "testing/testmain.h"

#include <QtCore/QStringList>
#include <QtCore/QTemporaryDir>
#include <QtTest/QSignalSpy>
#include <QtTest/QTest>

#include <memory>

using c7::tailscale::LocalApiClient;
using c7::testing::FakeSocketServer;

class TestLocalApiClient : public QObject {
    Q_OBJECT

private slots:
    void init()
    {
        // A fresh directory per test, so no test sees another's leftovers.
        dir = std::make_unique<QTemporaryDir>();
        QVERIFY(dir->isValid());
    }

    void getReturnsTheBodyWithoutHeaders()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(replied.wait());
        QCOMPARE(replied.first().at(1).toByteArray().trimmed(), QByteArrayLiteral("{\"ok\":true}"));
    }

    void sendsAHostHeaderTailscaledAccepts()
    {
        // tailscaled refuses a request without one; local-tailscaled.sock is
        // what its own client sends.
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(replied.wait());
        QCOMPARE(server.requests().size(), 1);
        QCOMPARE(server.requests().first(),
                 QByteArrayLiteral("GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock"));
    }

    void getReassemblesAChunkedBody()
    {
        // tailscaled answers /status -- the endpoint the whole backend stands
        // on -- with Transfer-Encoding: chunked. A body handed on with its
        // framing still in it begins "6e2f\r\n{" and is not JSON.
        const QByteArray reply =
            QByteArrayLiteral("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            + QByteArrayLiteral("6\r\n{\"a\":1\r\n")
            + QByteArrayLiteral("7\r\n,\"b\":2}\r\n")
            + QByteArrayLiteral("0\r\n\r\n");
        FakeSocketServer server(socketPath());
        server.onRequest([reply](const QByteArray &) { return reply; },
                         FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(replied.wait());
        QCOMPARE(replied.first().at(1).toByteArray(), QByteArrayLiteral("{\"a\":1,\"b\":2}"));
        QCOMPARE(failed.count(), 0);
    }

    void readsABodyThatEndsAtTheClose()
    {
        // Neither Content-Length nor chunked: the body is whatever had arrived
        // when the connection closed, so the close has to complete the
        // response off what the final drain brought, not call it unfinished.
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n{\"ok\":true}");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(replied.wait());
        QCOMPARE(replied.first().at(1).toByteArray(), QByteArrayLiteral("{\"ok\":true}"));
        QCOMPARE(failed.count(), 0);
    }

    void failsRatherThanHangingWhenTheSocketIsAbsent()
    {
        LocalApiClient c(socketPath() + QStringLiteral("-nope"));
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(failed.wait());
    }

    void failsOnANonSuccessStatus()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/prefs"));
        QVERIFY(failed.wait());
        QCOMPARE(failed.first().at(0).toString(), QStringLiteral("/localapi/v0/prefs"));
        QVERIFY2(failed.first().at(1).toString().contains(QStringLiteral("403")),
                 qPrintable(failed.first().at(1).toString()));
        QCOMPARE(replied.count(), 0);
    }

    void emitsOneEventPerCompleteLine()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ev(&c, &LocalApiClient::event);
        c.watch();
        // Wait for the request to be answered, not merely for the connection:
        // the fake writes the response headers when it reads the request, so a
        // line pushed before that would reach the client ahead of them.
        QTRY_COMPARE(server.requests().size(), 1);
        server.pushLine(QByteArrayLiteral("{\"a\":1}"));
        server.pushLine(QByteArrayLiteral("{\"b\":2}"));
        QTRY_COMPARE(ev.count(), 2);
        QCOMPARE(ev.at(0).first().toByteArray(), QByteArrayLiteral("{\"a\":1}"));
    }

    // Nothing else says a watch is up: a get ends in replied, but a watch on a
    // quiet bus is indistinguishable from one that never connected until it
    // either sends something or dies.
    void saysWhenTheWatchIsEstablished()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QStringList order;
        connect(&c, &LocalApiClient::watchStarted, &c, [&order] {
            order << QStringLiteral("watchStarted");
        });
        connect(&c, &LocalApiClient::event, &c, [&order](const QByteArray &) {
            order << QStringLiteral("event");
        });
        c.watch();
        QTRY_COMPARE(order, QStringList({QStringLiteral("watchStarted")}));
        // Once per watch, and ahead of the first notification.
        server.pushLine(QByteArrayLiteral("{\"a\":1}"));
        server.pushLine(QByteArrayLiteral("{\"b\":2}"));
        QTRY_COMPARE(order.size(), 3);
        QCOMPARE(order.first(), QStringLiteral("watchStarted"));
        QCOMPARE(order.count(QStringLiteral("watchStarted")), 1);
    }

    void neverSaysAWatchStartedWhenItWasRefused()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy started(&c, &LocalApiClient::watchStarted);
        QSignalSpy ended(&c, &LocalApiClient::watchEnded);
        c.watch();
        QVERIFY(ended.wait());
        QCOMPARE(started.count(), 0);
    }

    // A get is not a stream, however it is framed.
    void neverSaysAWatchStartedForAGet()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy started(&c, &LocalApiClient::watchStarted);
        QSignalSpy replied(&c, &LocalApiClient::replied);
        c.get(QStringLiteral("/localapi/v0/prefs"));
        QVERIFY(replied.wait());
        QCOMPARE(started.count(), 0);
    }

    // mask=1 is watch-engine-updates, not the floor this once claimed it was:
    // on a live tailscaled 1.104.1 it delivers a notification every 2.0s
    // carrying nothing but byte counters. The mask governs the initial
    // snapshot, not whether ongoing changes arrive, so the engine bit is not
    // ours to ask for.
    //
    // 16 is NotifyNoPrivateKeys, which tells tailscaled to strip private key
    // material out of what it sends. Measured on the same daemon: the
    // subscribe-time notification for mask=18 is byte-identical to the one
    // for mask=2, so the bit costs nothing, and omitting it would be a choice
    // to let key material through our buffers for no gain at all.
    void watchesWithoutTheEngineUpdateBitAndWithoutPrivateKeys()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        c.watch();
        QTRY_COMPARE(server.requests().size(), 1);
        const QByteArray request = server.requests().first();
        QVERIFY2(request.contains("/localapi/v0/watch-ipn-bus?mask=18"), request.constData());
    }

    void neverEmitsAPartialLine()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ev(&c, &LocalApiClient::event);
        c.watch();
        QTRY_COMPARE(server.requests().size(), 1);
        server.pushChunk(QByteArrayLiteral("{\"half\":"));   // no newline yet
        QTest::qWait(50);
        QCOMPARE(ev.count(), 0);
        server.pushChunk(QByteArrayLiteral("1}\n"));
        QTRY_COMPARE(ev.count(), 1);
        QCOMPARE(ev.first().first().toByteArray(), QByteArrayLiteral("{\"half\":1}"));
    }

    void joinsAWatchLineSplitAcrossChunks()
    {
        // The watch stream is chunked too, and a chunk boundary falls where
        // tailscaled flushed -- mid-notification as readily as between two.
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ev(&c, &LocalApiClient::event);
        c.watch();
        QTRY_COMPARE(server.requests().size(), 1);
        server.pushChunk(QByteArrayLiteral("4\r\n{\"ha\r\n"));   // half a notification
        QTest::qWait(50);
        QCOMPARE(ev.count(), 0);
        server.pushChunk(QByteArrayLiteral("7\r\nlf\":1}\n\r\n"));
        QTRY_COMPARE(ev.count(), 1);
        QCOMPARE(ev.first().first().toByteArray(), QByteArrayLiteral("{\"half\":1}"));
    }

    void waitsForAChunkSizeLineSplitAcrossReads()
    {
        // The size line is as much a stream as the data: "11" can arrive as
        // "1" and "1".
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ev(&c, &LocalApiClient::event);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.watch();
        QTRY_COMPARE(server.requests().size(), 1);
        server.pushChunk(QByteArrayLiteral("1"));
        QTest::qWait(50);
        QCOMPARE(ev.count(), 0);
        QCOMPARE(failed.count(), 0);           // half a length is not a bad one
        server.pushChunk(QByteArrayLiteral("1\r\n{\"chunk\":\"size\"}\n\r\n")); // 0x11 = 17
        QTRY_COMPARE(ev.count(), 1);
        QCOMPARE(ev.first().first().toByteArray(), QByteArrayLiteral("{\"chunk\":\"size\"}"));
    }

    void endsTheWatchOnTheLastChunk()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ended(&c, &LocalApiClient::watchEnded);
        c.watch();
        QTRY_COMPARE(server.requests().size(), 1);
        server.pushChunk(QByteArrayLiteral("0\r\n\r\n"));
        QVERIFY(ended.wait());
        QCOMPARE(ended.count(), 1);
    }

    void endsTheWatchWhenTailscaledGoes()
    {
        // What a backend reconnects on: tailscaled restarting takes the socket
        // with it.
        auto server = std::make_unique<FakeSocketServer>(socketPath());
        server->onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ended(&c, &LocalApiClient::watchEnded);
        c.watch();
        QTRY_COMPARE(server->clientCount(), 1);
        server.reset();
        QVERIFY(ended.wait());
        QCOMPARE(ended.count(), 1);
    }

    void aFailingWatchSaysWhyAndThenThatItEnded()
    {
        // Two signals, in this order. A watch is the one path that ends in
        // both: a caller restarts on watchEnded and wants failed's reason, so
        // it must not have to guess which of the two it is given.
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QStringList order;
        connect(&c, &LocalApiClient::failed, &c, [&order](const QString &, const QString &) {
            order << QStringLiteral("failed");
        });
        connect(&c, &LocalApiClient::watchEnded, &c, [&order] {
            order << QStringLiteral("watchEnded");
        });
        c.watch();
        QTRY_COMPARE(order,
                     QStringList({QStringLiteral("failed"), QStringLiteral("watchEnded")}));
    }

    // A socket that is open and silent emits nothing at all -- no readyRead,
    // no disconnected, no errorOccurred -- so without a deadline a get has no
    // terminal signal and a caller tracking a request in flight is latched on
    // a reply that is never coming. This is tailscaled wedged, or TS_SOCKET
    // naming some other listening socket.
    void aGetWithNoAnswerAtAllEndsInFailedAtItsDeadline()
    {
        FakeSocketServer server(socketPath());
        // No handler: the request is recorded and the client is left open and
        // unanswered, which is the hang this exists for.
        server.onRequest(FakeSocketServer::Handler{}, FakeSocketServer::KeepOpen, "\r\n\r\n");
        // 50ms rather than the shipped ten seconds: a test may not sleep out
        // the real one (docs/architecture.md:204), which is why the deadline
        // is a constructor parameter.
        LocalApiClient c(socketPath(), 50);
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        // The request arrived: the socket really is connected and silent, not
        // refused -- otherwise errorOccurred would end this and the deadline
        // would prove nothing.
        QTRY_COMPARE(server.requests().size(), 1);
        QVERIFY(failed.wait());
        QCOMPARE(failed.first().at(0).toString(), QStringLiteral("/localapi/v0/status"));
        QVERIFY2(failed.first().at(1).toString().contains(QStringLiteral("50 ms")),
                 qPrintable(failed.first().at(1).toString()));
        QCOMPARE(replied.count(), 0);
    }

    // The deadline is on the whole exchange, not on the headers: a reply that
    // announces a body and then stops is the same latch one step later.
    void aGetWhoseBodyNeverArrivesEndsInFailedAtItsDeadline()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n{\"Backend");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath(), 50);
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(failed.wait());
        QCOMPARE(replied.count(), 0);
    }

    // A watch that is refused outright never says watchStarted, and one that
    // is never answered at all must not be any quieter: failed then
    // watchEnded, in that order, like every other way a watch ends badly.
    void aWatchThatNeverStartsEndsInFailedAndThenWatchEnded()
    {
        FakeSocketServer server(socketPath());
        server.onRequest(FakeSocketServer::Handler{}, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath(), 50);
        QStringList order;
        QString reason;
        connect(&c, &LocalApiClient::watchStarted, &c, [&order] { order << QStringLiteral("watchStarted"); });
        connect(&c, &LocalApiClient::failed, &c, [&order, &reason](const QString &, const QString &why) {
            order << QStringLiteral("failed");
            reason = why;
        });
        connect(&c, &LocalApiClient::watchEnded, &c, [&order] { order << QStringLiteral("watchEnded"); });
        c.watch();
        QTRY_COMPARE(order,
                     QStringList({QStringLiteral("failed"), QStringLiteral("watchEnded")}));
        QVERIFY2(reason.contains(QStringLiteral("did not start")), qPrintable(reason));
    }

    // The other half of that rule, and the reason the watch's deadline stops
    // at its headers: a quiet bus is the normal state of a tailnet -- measured
    // silent for 20s on a live daemon, and capable of hours -- so a watch
    // timed out on silence would be a reconnect loop on a healthy machine.
    void anEstablishedWatchIsNotTimedOutByAQuietBus()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath(), 50);
        QSignalSpy started(&c, &LocalApiClient::watchStarted);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        QSignalSpy ended(&c, &LocalApiClient::watchEnded);
        QSignalSpy ev(&c, &LocalApiClient::event);
        c.watch();
        QVERIFY(started.wait());
        // Four deadlines' worth of silence. Proving a negative needs a bounded
        // wait, which is the shape the rest of this file uses for one.
        QTest::qWait(200);
        QCOMPARE(failed.count(), 0);
        QCOMPARE(ended.count(), 0);
        // And it is still a live stream afterwards, not merely an unreported
        // dead one.
        server.pushLine(QByteArrayLiteral("{\"State\":6}"));
        QTRY_COMPARE(ev.count(), 1);
    }

    // The token is handed back untouched, on both endings, so a caller that
    // asks the same endpoint twice can tell the two replies apart. A path
    // cannot do that -- ask twice and both say "/localapi/v0/prefs" -- which
    // is what let a reply from an abandoned round be paired with the round
    // after it.
    void handsTheTokenBackOnTheReply()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        c.get(QStringLiteral("/localapi/v0/prefs"), 7);
        QVERIFY(replied.wait());
        QCOMPARE(replied.first().at(2).toULongLong(), 7u);
    }

    void handsTheTokenBackOnTheFailure()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/prefs"), 9);
        QVERIFY(failed.wait());
        QCOMPARE(failed.first().at(2).toULongLong(), 9u);
    }

    // Untagged by default, for a caller with one request in flight and
    // nothing to disambiguate -- and the watch is always untagged, because a
    // stream is not a round of asking.
    void reportsZeroForAnUntaggedGetAndForTheWatch()
    {
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &request) -> QByteArray {
            if (request.contains("/localapi/v0/watch-ipn-bus"))
                return QByteArrayLiteral("HTTP/1.1 500 Server Error\r\nContent-Length: 0\r\n\r\n");
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}");
        }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy replied(&c, &LocalApiClient::replied);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.get(QStringLiteral("/localapi/v0/status"));
        QVERIFY(replied.wait());
        QCOMPARE(replied.first().at(2).toULongLong(), 0u);
        c.watch();
        QVERIFY(failed.wait());
        QCOMPARE(failed.first().at(2).toULongLong(), 0u);
    }

    void saysNothingWhenTheWatchIsStopped()
    {
        // stop() is the caller's own doing, so it reports no ending: a caller
        // that reconnects on watchEnded must not fight its own stop().
        FakeSocketServer server(socketPath());
        server.onRequest([](const QByteArray &) {
            return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
        }, FakeSocketServer::KeepOpen, "\r\n\r\n");
        LocalApiClient c(socketPath());
        QSignalSpy ended(&c, &LocalApiClient::watchEnded);
        QSignalSpy failed(&c, &LocalApiClient::failed);
        c.watch();
        QTRY_COMPARE(server.clientCount(), 1);
        c.stop();
        QTRY_COMPARE(server.clientCount(), 0);
        QTest::qWait(50);
        QCOMPARE(ended.count(), 0);
        QCOMPARE(failed.count(), 0);
    }

private:
    // Under this test's own directory: no test may reach the real
    // /var/run/tailscale/tailscaled.sock.
    QString socketPath() const
    {
        return dir->filePath(QStringLiteral("tailscale/tailscaled.sock"));
    }

    std::unique_ptr<QTemporaryDir> dir;
};

C7_TEST_MAIN(TestLocalApiClient)
#include "tst_localapiclient.moc"
