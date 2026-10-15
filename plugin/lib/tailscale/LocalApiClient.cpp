#include "tailscale/LocalApiClient.h"

#include <QtCore/QList>
#include <QtCore/QTimer>
#include <QtNetwork/QLocalSocket>

namespace c7::tailscale {

namespace {

// mask=1 is notifyState: the stream the real client asks for.
const QString kWatchPath = QStringLiteral("/localapi/v0/watch-ipn-bus?mask=1");

constexpr auto kHeaderEnd = "\r\n\r\n";
constexpr qsizetype kHeaderEndSize = 4;

// The header block's first line, "HTTP/1.1 200 OK" -- or all of it when that
// is the only line, which is how watch-ipn-bus answers. Qt 6's left(-1) is
// empty, not the whole string, so the missing CRLF is spelt out.
QByteArray statusLine(const QByteArray &head)
{
    const qsizetype end = head.indexOf("\r\n");
    return end < 0 ? head : head.left(end);
}

// The code out of the status line; 0 when it is not one.
int statusCode(const QByteArray &head)
{
    const QList<QByteArray> words = statusLine(head).simplified().split(' ');
    if (words.size() < 2 || !words.first().startsWith("HTTP/"))
        return 0;
    bool ok = false;
    const int code = words.at(1).toInt(&ok);
    return ok ? code : 0;
}

// Content-Length, or -1 when the response does not say -- which is how
// watch-ipn-bus answers, and which leaves the body ending at the close.
qsizetype contentLength(const QByteArray &head)
{
    const QList<QByteArray> lines = head.split('\n');
    for (const QByteArray &line : lines) {
        const qsizetype colon = line.indexOf(':');
        if (colon < 0 || line.left(colon).trimmed().toLower() != "content-length")
            continue;
        bool ok = false;
        const qsizetype length = line.mid(colon + 1).trimmed().toLongLong(&ok);
        return ok ? length : -1;
    }
    return -1;
}

} // namespace

LocalApiClient::LocalApiClient(QString socketPath, QObject *parent)
    : QObject(parent), m_socketPath(std::move(socketPath))
{
}

LocalApiClient::~LocalApiClient()
{
    stop();
}

void LocalApiClient::get(const QString &path)
{
    start(path, false);
}

void LocalApiClient::watch()
{
    start(kWatchPath, true);
}

void LocalApiClient::stop()
{
    const QList<QLocalSocket *> sockets = m_exchanges.keys();
    for (QLocalSocket *socket : sockets)
        take(socket);
}

void LocalApiClient::start(const QString &path, bool streaming)
{
    auto *socket = new QLocalSocket(this);
    Exchange exchange;
    exchange.path = path;
    exchange.streaming = streaming;
    m_exchanges.insert(socket, exchange);

    const QByteArray request =
        "GET " + path.toUtf8() + " HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n";
    // Written once connected rather than straight away: a connection that
    // never happens must end in errorOccurred, not in a buffered write.
    connect(socket, &QLocalSocket::connected, this, [socket, request] { socket->write(request); });
    connect(socket, &QLocalSocket::readyRead, this, [this, socket] { read(socket); });
    connect(socket, &QLocalSocket::disconnected, this, [this, socket] { closed(socket); });
    connect(socket, &QLocalSocket::errorOccurred, this, [this, socket] { errored(socket); });
    // Connected from the event loop rather than here: on Unix a socket that
    // cannot connect fails inside connectToServer(), and a caller must not
    // have to handle an outcome that arrives before get() has returned. Every
    // request ends the same way, through the event loop, socket or no socket.
    QTimer::singleShot(0, socket, [this, socket] {
        // stop() may have taken this one away in the meantime.
        if (m_exchanges.contains(socket))
            socket->connectToServer(m_socketPath);
    });
}

void LocalApiClient::read(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return;
    it->buffer += socket->readAll();

    if (!it->headersDone) {
        const qsizetype at = it->buffer.indexOf(kHeaderEnd);
        // Headers split across reads: nothing to decide until they are whole.
        if (at < 0)
            return;
        const QByteArray head = it->buffer.left(at);
        it->buffer.remove(0, at + kHeaderEndSize);
        const int code = statusCode(head);
        if (code < 200 || code >= 300) {
            fail(socket, QStringLiteral("%1 answered %2")
                             .arg(it->path, QString::fromUtf8(statusLine(head))));
            return; // fail() took the exchange; `it` is gone with it
        }
        it->headersDone = true;
        it->contentLength = contentLength(head);
    }

    if (it->streaming) {
        emitLines(socket);
        return;
    }
    // Without a Content-Length the body ends when the server closes, which
    // closed() handles.
    if (it->contentLength >= 0 && it->buffer.size() >= it->contentLength)
        finish(socket);
}

void LocalApiClient::emitLines(QLocalSocket *socket)
{
    // A stream keeps no write boundaries: one notification can arrive in two
    // reads and two in one, so only what a newline has closed is an event.
    //
    // The exchange is looked up again each time round because a slot of
    // event() may stop the watch, which takes it away under us.
    for (;;) {
        const auto it = m_exchanges.find(socket);
        if (it == m_exchanges.end())
            return;
        const qsizetype at = it->buffer.indexOf('\n');
        if (at < 0)
            return;
        QByteArray line = it->buffer.left(at);
        it->buffer.remove(0, at + 1);
        if (line.endsWith('\r'))
            line.chop(1);
        if (!line.isEmpty())
            emit event(line);
    }
}

void LocalApiClient::closed(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return;
    // Whatever the close left unread is still part of the response.
    it->buffer += socket->readAll();
    if (!it->headersDone) {
        fail(socket, QStringLiteral("the connection closed before the response headers"));
        return;
    }
    if (it->streaming)
        emitLines(socket);
    finish(socket);
}

void LocalApiClient::errored(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return;
    // tailscaled closing a response it has finished is an ending, not a
    // failure; Qt reports that close as an error on some paths.
    if (socket->error() == QLocalSocket::PeerClosedError && it->headersDone) {
        closed(socket);
        return;
    }
    fail(socket, socket->errorString());
}

void LocalApiClient::finish(QLocalSocket *socket)
{
    const std::optional<Exchange> exchange = take(socket);
    if (!exchange)
        return;
    if (exchange->streaming) {
        emit watchEnded();
        return;
    }
    emit replied(exchange->path, exchange->contentLength >= 0
                                     ? exchange->buffer.left(exchange->contentLength)
                                     : exchange->buffer);
}

void LocalApiClient::fail(QLocalSocket *socket, const QString &reason)
{
    const std::optional<Exchange> exchange = take(socket);
    if (!exchange)
        return;
    emit failed(exchange->path, reason);
    if (exchange->streaming)
        emit watchEnded();
}

std::optional<LocalApiClient::Exchange> LocalApiClient::take(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return std::nullopt;
    const Exchange exchange = *it;
    m_exchanges.erase(it);
    // No late signal from a socket whose ending has already been reported.
    socket->disconnect(this);
    socket->abort();
    socket->deleteLater();
    return exchange;
}

} // namespace c7::tailscale
