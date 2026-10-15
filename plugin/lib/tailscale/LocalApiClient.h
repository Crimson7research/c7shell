#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>

#include <optional>

class QLocalSocket;

namespace c7::tailscale {

// HTTP over tailscaled's local API socket, /var/run/tailscale/tailscaled.sock,
// which answers GET /localapi/v0/status, /prefs and /suggest-exit-node
// unprivileged, and streams change notifications from /watch-ipn-bus.
//
// It exists so nothing has to spawn the `tailscale` CLI: docs/architecture.md
// forbids a backend to start processes, and the CLI could only be polled,
// while watch-ipn-bus pushes -- tailscaled's answer to NetworkManager's
// PropertiesChanged. Nothing here blocks: no waitForReadyRead, no nested event
// loop. This runs on the QML engine's thread, where a stall freezes the bar.
//
// One socket per request, so a reply and a running watch never queue behind
// each other. Every path ends in exactly one signal: replied or failed for a
// get, watchEnded for a watch -- save a watch the caller stops itself, which
// is silent so a caller that reconnects on watchEnded does not fight stop().
class LocalApiClient : public QObject {
    Q_OBJECT

public:
    explicit LocalApiClient(QString socketPath, QObject *parent = nullptr);
    ~LocalApiClient() override;

    // GET `path`, answered by replied() or failed().
    void get(const QString &path);

    // Stream /localapi/v0/watch-ipn-bus: one event() per complete line, then
    // watchEnded() when the stream stops.
    void watch();

    // Drop everything in flight, the watch included. Emits nothing.
    void stop();

signals:
    // The response body, headers stripped.
    void replied(const QString &path, const QByteArray &body);
    void failed(const QString &path, const QString &reason);
    // One complete notification. Never a partial line: a line split across two
    // reads is held until the newline arrives.
    void event(const QByteArray &line);
    void watchEnded();

private:
    struct Exchange {
        QString path;
        QByteArray buffer;
        bool streaming = false;
        bool headersDone = false;
        qsizetype contentLength = -1;
    };

    void start(const QString &path, bool streaming);
    void read(QLocalSocket *socket);
    void emitLines(QLocalSocket *socket);
    void closed(QLocalSocket *socket);
    void errored(QLocalSocket *socket);
    void finish(QLocalSocket *socket);
    void fail(QLocalSocket *socket, const QString &reason);
    // Forget `socket` and hand back what it was doing, once: whoever takes an
    // exchange owns the ending, so no response is reported twice.
    std::optional<Exchange> take(QLocalSocket *socket);

    QString m_socketPath;
    QHash<QLocalSocket *, Exchange> m_exchanges;
};

} // namespace c7::tailscale
