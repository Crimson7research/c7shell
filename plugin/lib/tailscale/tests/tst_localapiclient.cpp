#include "tailscale/LocalApiClient.h"

#include "testing/fakesocketserver.h"
#include "testing/testmain.h"

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
