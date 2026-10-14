#include "testing/fakesocketserver.h"
#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QTemporaryDir>
#include <QtNetwork/QLocalSocket>
#include <QtTest/QTest>

using c7::testing::FakeSocketServer;
using c7::testing::waitUntil;

namespace {

// A client the way a library under test would be one: connect, write, read.
// Null when it could not connect.
std::unique_ptr<QLocalSocket> connectTo(const QString &path)
{
    auto s = std::make_unique<QLocalSocket>();
    s->connectToServer(path);
    if (!waitUntil([&] { return s->state() == QLocalSocket::ConnectedState; }))
        return nullptr;
    return s;
}

// Read until `done(got)` holds; false at the bound.
template <typename Done>
bool readUntil(QLocalSocket &s, QByteArray &got, Done done)
{
    return waitUntil([&] {
        got += s.readAll();
        return done(got);
    });
}

} // namespace

class TestFakeSocketServer : public QObject {
    Q_OBJECT

private slots:
    void init()
    {
        // A fresh directory per test, so no test sees another's leftovers.
        dir = std::make_unique<QTemporaryDir>();
        QVERIFY(dir->isValid());
        // Nested, as Hyprland's are: $XDG_RUNTIME_DIR/hypr/<signature>/.socket.sock
        path = dir->filePath(QStringLiteral("hypr/sig/.socket.sock"));
    }

    void listensAtTheGivenPathForThisUserOnly()
    {
        FakeSocketServer server(path);
        QVERIFY2(server.isListening(), qPrintable(server.error()));
        QCOMPARE(server.path(), path);
        QVERIFY(QFileInfo::exists(path));
        const QFile::Permissions others = QFile::ReadGroup | QFile::WriteGroup | QFile::ReadOther
                                          | QFile::WriteOther;
        QCOMPARE(QFileInfo(path).permissions() & others, QFile::Permissions{});
    }

    void repliesAndClosesLikeARequestSocket()
    {
        FakeSocketServer server(path);
        server.onRequest([](const QByteArray &req) { return "ok:" + req; });
        auto client = connectTo(path);
        QVERIFY(client);
        client->write("dispatch workspace 2");

        QByteArray got;
        QVERIFY(readUntil(*client, got, [&](const QByteArray &) {
            return client->state() == QLocalSocket::UnconnectedState;
        }));
        got += client->readAll();
        QCOMPARE(got, QByteArray("ok:dispatch workspace 2"));
        QCOMPARE(server.requests(), QByteArrayList{"dispatch workspace 2"});
    }

    void canKeepTheClientOpen()
    {
        FakeSocketServer server(path);
        server.onRequest([](const QByteArray &) { return QByteArray("pong"); },
                         FakeSocketServer::KeepOpen);
        auto client = connectTo(path);
        QVERIFY(client);
        for (int i = 0; i < 2; ++i) {
            client->write("ping");
            QByteArray got;
            QVERIFY(readUntil(*client, got, [](const QByteArray &g) { return g == "pong"; }));
        }
        QCOMPARE(client->state(), QLocalSocket::ConnectedState);
        QCOMPARE(server.requests().size(), 2);
    }

    void splitsFramedRequestsWhateverTheReadsLookLike()
    {
        // A stream keeps no write boundaries; with a delimiter the server does.
        FakeSocketServer server(path);
        server.onRequest([](const QByteArray &req) { return "<" + req + ">"; },
                         FakeSocketServer::KeepOpen, "\n");
        auto client = connectTo(path);
        QVERIFY(client);
        client->write("one\ntw");
        client->flush();
        client->write("o\nthree");
        QByteArray got;
        QVERIFY(readUntil(*client, got, [](const QByteArray &g) { return g == "<one><two>"; }));
        QCOMPARE(server.requests(), (QByteArrayList{"one", "two"}));
        // "three" has no delimiter yet, so it is not a request yet.
        client->write("\n");
        QVERIFY(readUntil(*client, got, [](const QByteArray &g) { return g.endsWith("<three>"); }));
    }

    void answersNothingAfterClosing()
    {
        // Two framed requests in one read: the first reply closes the client,
        // so the second is neither answered nor recorded.
        FakeSocketServer server(path);
        server.onRequest([](const QByteArray &req) { return req; }, FakeSocketServer::CloseAfterReply,
                         "\n");
        auto client = connectTo(path);
        QVERIFY(client);
        client->write("a\nb\n");
        QByteArray got;
        QVERIFY(readUntil(*client, got, [&](const QByteArray &) {
            return client->state() == QLocalSocket::UnconnectedState;
        }));
        got += client->readAll();
        QCOMPARE(got, QByteArray("a"));
        QCOMPARE(server.requests(), QByteArrayList{"a"});
    }

    void pushesLinesToEveryClientLikeAnEventSocket()
    {
        FakeSocketServer server(path);
        auto first = connectTo(path);
        auto second = connectTo(path);
        QVERIFY(first && second);
        QVERIFY(waitUntil([&] { return server.clientCount() == 2; }));

        QCOMPARE(server.pushLine("workspace>>2"), 2);
        QByteArray a;
        QByteArray b;
        QVERIFY(readUntil(*first, a, [](const QByteArray &g) { return g.endsWith('\n'); }));
        QVERIFY(readUntil(*second, b, [](const QByteArray &g) { return g.endsWith('\n'); }));
        QCOMPARE(a, QByteArray("workspace>>2\n"));
        QCOMPARE(b, QByteArray("workspace>>2\n"));
    }

    void saysWhenALineReachedNobody()
    {
        FakeSocketServer server(path);
        QCOMPARE(server.pushLine("workspace>>2"), 0);
    }

    void recordsRequestsWithoutAHandler()
    {
        FakeSocketServer server(path);
        auto client = connectTo(path);
        QVERIFY(client);
        client->write("j/clients");
        QVERIFY(waitUntil([&] { return !server.requests().isEmpty(); }));
        QCOMPARE(server.requests().first(), QByteArray("j/clients"));
        QCOMPARE(client->state(), QLocalSocket::ConnectedState);
    }

    void disconnectsItsClientsAndRemovesTheSocketWhenDestroyed()
    {
        // What a library test uses to play Hyprland exiting.
        auto server = std::make_unique<FakeSocketServer>(path);
        auto first = connectTo(path);
        auto second = connectTo(path);
        QVERIFY(first && second);
        QVERIFY(waitUntil([&] { return server->clientCount() == 2; }));
        server.reset();
        QVERIFY(waitUntil([&] {
            return first->state() == QLocalSocket::UnconnectedState
                   && second->state() == QLocalSocket::UnconnectedState;
        }));
        QVERIFY(!QFileInfo::exists(path));
    }

    void refusesAPathAlreadyTaken_data()
    {
        QTest::addColumn<QString>("what");
        QTest::newRow("another server") << QStringLiteral("server");
        QTest::newRow("a file") << QStringLiteral("file");
        QTest::newRow("a dangling symlink") << QStringLiteral("symlink");
    }

    void refusesAPathAlreadyTaken()
    {
        QFETCH(QString, what);
        const bool liveServer = what == QLatin1String("server");
        std::unique_ptr<FakeSocketServer> first;
        if (liveServer) {
            first = std::make_unique<FakeSocketServer>(path);
            QVERIFY(first->isListening());
        } else if (what == QLatin1String("file")) {
            QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
            QFile f(path);
            QVERIFY(f.open(QIODevice::WriteOnly));
        } else {
            QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
            QVERIFY(QFile::link(dir->filePath(QStringLiteral("nowhere")), path));
        }
        {
            FakeSocketServer second(path);
            QVERIFY(!second.isListening());
            QVERIFY2(second.error().contains(QLatin1String("already exists")), qPrintable(second.error()));
        }
        // The refused one removed nothing (a dangling link does not "exist").
        QVERIFY(QFileInfo(path).exists() || QFileInfo(path).isSymLink());
        if (liveServer)
            QVERIFY(connectTo(path));
    }

    void reportsADirectoryItCannotCreate()
    {
        QFile blocker(dir->filePath(QStringLiteral("hypr")));
        QVERIFY(blocker.open(QIODevice::WriteOnly)); // a file where the directory goes
        FakeSocketServer server(path);
        QVERIFY(!server.isListening());
        QVERIFY(!server.error().isEmpty());
    }

    void reportsAPathTooLongToListenOn()
    {
        FakeSocketServer server(dir->filePath(QString(200, QLatin1Char('s'))));
        QVERIFY(!server.isListening());
        QVERIFY(!server.error().isEmpty());
    }

private:
    std::unique_ptr<QTemporaryDir> dir;
    QString path;
};

C7_TEST_MAIN(TestFakeSocketServer)
#include "tst_fakesocketserver.moc"
