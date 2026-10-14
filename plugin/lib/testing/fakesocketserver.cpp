#include "testing/fakesocketserver.h"

#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtNetwork/QLocalSocket>

namespace c7::testing {

FakeSocketServer::FakeSocketServer(const QString &path, QObject *parent)
    : QObject(parent), m_path(path)
{
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        m_error = QStringLiteral("cannot create the directory for %1").arg(path);
        return;
    }
    // QLocalServer::listen() unlinks whatever is at the path, a live server's
    // socket included; a fixture must never do that.
    if (QFileInfo(path).exists() || QFileInfo(path).isSymLink()) {
        m_error = QStringLiteral("%1 already exists").arg(path);
        return;
    }
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    if (!m_server.listen(path)) {
        m_error = m_server.errorString();
        return;
    }
    connect(&m_server, &QLocalServer::newConnection, this, &FakeSocketServer::accept);
}

FakeSocketServer::~FakeSocketServer()
{
    // abort() emits disconnected() synchronously, and its handler edits
    // m_clients: take the list first and drop the handlers before aborting.
    const QList<QPointer<QLocalSocket>> clients = std::exchange(m_clients, {});
    for (const QPointer<QLocalSocket> &c : clients) {
        if (!c)
            continue;
        c->disconnect(this);
        c->abort();
    }
    m_server.close();
}

void FakeSocketServer::onRequest(Handler handler, AfterReply after, const QByteArray &delimiter)
{
    m_handler = std::move(handler);
    m_after = after;
    m_delimiter = delimiter;
}

int FakeSocketServer::pushLine(const QByteArray &line)
{
    // A copy: a write that fails can disconnect a client, which edits m_clients.
    const QList<QPointer<QLocalSocket>> clients = m_clients;
    int reached = 0;
    for (const QPointer<QLocalSocket> &c : clients) {
        if (c && c->state() == QLocalSocket::ConnectedState && c->write(line + '\n') == line.size() + 1)
            ++reached;
    }
    return reached;
}

void FakeSocketServer::accept()
{
    while (QLocalSocket *client = m_server.nextPendingConnection()) {
        m_clients << client;
        connect(client, &QLocalSocket::readyRead, this, [this, client] { read(client); });
        connect(client, &QLocalSocket::disconnected, this, [this, client] {
            m_clients.removeAll(client);
            m_pending.remove(client);
            client->deleteLater();
        });
    }
}

void FakeSocketServer::read(QLocalSocket *client)
{
    const QByteArray bytes = client->readAll();
    if (bytes.isEmpty())
        return;
    if (m_delimiter.isEmpty()) {
        answer(client, bytes);
        return;
    }
    QByteArray &pending = m_pending[client];
    pending += bytes;
    qsizetype at;
    // A reply may close the client; nothing after that is a request. A
    // disconnect also drops the client's pending bytes.
    while (m_pending.contains(client) && client->state() == QLocalSocket::ConnectedState
           && (at = pending.indexOf(m_delimiter)) >= 0) {
        const QByteArray request = pending.left(at);
        pending.remove(0, at + m_delimiter.size());
        answer(client, request);
    }
}

void FakeSocketServer::answer(QLocalSocket *client, const QByteArray &request)
{
    m_requests << request;
    if (!m_handler)
        return;
    client->write(m_handler(request));
    if (m_after == CloseAfterReply)
        client->disconnectFromServer();
}

} // namespace c7::testing
