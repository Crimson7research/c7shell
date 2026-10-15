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

// A header's value, empty when the block does not carry it. `name` is lower
// case; the status line, having no colon, is skipped like any other mismatch.
QByteArray headerValue(const QByteArray &head, const QByteArray &name)
{
    const QList<QByteArray> lines = head.split('\n');
    for (const QByteArray &line : lines) {
        const qsizetype colon = line.indexOf(':');
        if (colon >= 0 && line.left(colon).trimmed().toLower() == name)
            return line.mid(colon + 1).trimmed();
    }
    return {};
}

// Content-Length, or -1 when the response does not give one -- which is how a
// chunked response answers, and which otherwise leaves the body ending at the
// close.
qsizetype contentLength(const QByteArray &head)
{
    bool ok = false;
    const qsizetype length = headerValue(head, "content-length").toLongLong(&ok);
    return ok ? length : -1;
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
    deliver(socket);
}

void LocalApiClient::deliver(QLocalSocket *socket)
{
    if (!readHeaders(socket) || !unframe(socket))
        return;
    auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return;
    if (it->streaming) {
        emitLines(socket);
        // A slot of event() may have stopped the watch: look again.
        it = m_exchanges.find(socket);
        if (it != m_exchanges.end() && it->ended)
            finish(socket);
        return;
    }
    // Without either framing the body ends at the close, which closed() takes.
    if (it->ended || (it->contentLength >= 0 && it->body.size() >= it->contentLength))
        finish(socket);
}

// False when the headers are not whole yet, or were refused.
bool LocalApiClient::readHeaders(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return false;
    if (it->headersDone)
        return true;
    const qsizetype at = it->buffer.indexOf(kHeaderEnd);
    // Headers split across reads: nothing to decide until they are whole.
    if (at < 0)
        return false;
    const QByteArray head = it->buffer.left(at);
    it->buffer.remove(0, at + kHeaderEndSize);
    const int code = statusCode(head);
    if (code < 200 || code >= 300) {
        fail(socket, QStringLiteral("%1 answered %2")
                         .arg(it->path, QString::fromUtf8(statusLine(head))));
        return false;
    }
    it->headersDone = true;
    it->chunked = headerValue(head, "transfer-encoding").toLower().contains("chunked");
    // A chunked response carries no Content-Length, and must not be cut to one.
    it->contentLength = it->chunked ? -1 : contentLength(head);
    return true;
}

// Move what has arrived from the raw buffer into the body, taking off chunk
// framing when there is any. False when the framing was refused.
bool LocalApiClient::unframe(QLocalSocket *socket)
{
    const auto it = m_exchanges.find(socket);
    if (it == m_exchanges.end())
        return false;
    if (!it->chunked) {
        it->body += it->buffer;
        it->buffer.clear();
        return true;
    }
    // A hex length, an optional ";extension", CRLF, that many bytes, CRLF,
    // until a zero length closes the body. Every piece of that can arrive
    // split -- the size line as readily as the data -- so each step either
    // completes or leaves the bytes where they are for the next read.
    while (!it->ended) {
        if (it->chunkLeft < 0) {
            const qsizetype eol = it->buffer.indexOf("\r\n");
            if (eol < 0)
                return true;
            QByteArray size = it->buffer.left(eol);
            const qsizetype extension = size.indexOf(';');
            if (extension >= 0)
                size = size.left(extension);
            bool ok = false;
            const qsizetype length = size.trimmed().toLongLong(&ok, 16);
            if (!ok || length < 0) {
                fail(socket, QStringLiteral("%1 sent \"%2\" where a chunk length belongs")
                                 .arg(it->path, QString::fromUtf8(size.trimmed())));
                return false;
            }
            it->buffer.remove(0, eol + 2);
            if (length == 0) {
                it->ended = true; // trailers, if any, are of no interest here
                break;
            }
            it->chunkLeft = length;
            continue;
        }
        if (it->chunkLeft > 0) {
            const qsizetype take = qMin(it->chunkLeft, it->buffer.size());
            if (take == 0)
                return true;
            it->body += it->buffer.left(take);
            it->buffer.remove(0, take);
            it->chunkLeft -= take;
            continue;
        }
        if (it->buffer.size() < 2)
            return true;
        if (!it->buffer.startsWith("\r\n")) {
            fail(socket, QStringLiteral("%1 sent a chunk that does not end where it said")
                             .arg(it->path));
            return false;
        }
        it->buffer.remove(0, 2);
        it->chunkLeft = -1;
    }
    return true;
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
        const qsizetype at = it->body.indexOf('\n');
        if (at < 0)
            return;
        QByteArray line = it->body.left(at);
        it->body.remove(0, at + 1);
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
    deliver(socket);
    const auto rest = m_exchanges.find(socket);
    if (rest == m_exchanges.end())
        return; // deliver() reported the ending already
    if (rest->streaming) {
        finish(socket); // tailscaled went: the watch is over, not broken
        return;
    }
    // A body cut short is not a body: a chunked response without its final
    // chunk, or fewer bytes than Content-Length promised, is a failure.
    if (rest->chunked || rest->contentLength > rest->body.size()) {
        fail(socket, QStringLiteral("the connection closed before the response ended"));
        return;
    }
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
                                     ? exchange->body.left(exchange->contentLength)
                                     : exchange->body);
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
