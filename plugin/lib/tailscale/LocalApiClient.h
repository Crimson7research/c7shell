#pragma once

#include <QtCore/QByteArray>
#include <QtCore/QHash>
#include <QtCore/QObject>
#include <QtCore/QString>

#include <optional>

class QLocalSocket;
class QTimer;

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
// each other. A get ends in exactly one signal, replied or failed. A watch
// begins with watchStarted, once its response headers have arrived and been
// accepted, and ends in watchEnded -- preceded by failed, in that order, when
// it ended because something went wrong, so a caller has both the reason and
// the trigger to restart on. A watch that is refused outright never emits
// watchStarted. A watch the caller stops itself is silent, so a caller that
// reconnects on watchEnded does not fight its own stop().
//
// Every exchange carries a deadline, because a socket that is open and silent
// emits nothing at all: no readyRead, no disconnected, no errorOccurred. A
// tailscaled that wedges, or a TS_SOCKET naming some other listening socket
// that never answers, would otherwise leave a get with no terminal signal for
// as long as the process lives -- and a caller that tracks a request in flight
// latched forever on a reply that is never coming. The deadline ends such an
// exchange in failed(), which is a terminal signal like any other, so the
// one-signal-per-path contract above holds whatever tailscaled does.
//
// What the deadline measures differs by shape, because the two shapes idle
// differently. A get is bounded end to end: tailscaled answers /status,
// /prefs and /suggest-exit-node immediately or not at all. A watch is bounded
// only to its ESTABLISHMENT -- its response headers -- and is unbounded after
// that: a quiet bus is the normal state of a tailnet and was measured sending
// nothing for 20s and potentially hours, so a watch timed out on silence
// would be a reconnect loop on a healthy machine.
//
// tailscaled answers /status and watch-ipn-bus with Transfer-Encoding:
// chunked, and /prefs and /suggest-exit-node with a Content-Length, so both
// framings are read here. Chunk framing comes off before anything looks for a
// newline: a chunk boundary falls wherever tailscaled flushed, which on the
// watch stream is as readily mid-notification as between two of them.
class LocalApiClient : public QObject {
    Q_OBJECT

public:
    // How long an exchange has, when a caller does not say. Long enough that
    // no working tailscaled reaches it -- only a wedged one does.
    static constexpr int kTimeoutMs = 10000;

    // `timeoutMs` is a parameter so a test can prove the deadline without
    // sleeping out the shipped one, which docs/architecture.md:204 forbids it
    // to do. Zero or less means no deadline at all, which is not a thing the
    // shell asks for: it exists so a test can stage a hung exchange.
    explicit LocalApiClient(QString socketPath, int timeoutMs = kTimeoutMs,
                            QObject *parent = nullptr);
    ~LocalApiClient() override;

    // GET `path`, answered by replied() or failed(), each carrying `token`
    // back unchanged.
    //
    // The token exists because a caller that assembles one view out of two
    // endpoints has to know WHICH round of asking a reply belongs to, and a
    // path cannot say: ask twice and both replies are "/localapi/v0/prefs".
    // A caller that abandons a round -- because the other endpoint failed --
    // then has no way to tell a straggler from that round apart from the
    // answer to the round it has just started, and will pair the straggler
    // with the new round's other half. This client cannot fix that for the
    // caller, because only the caller knows what a round is; it can only hand
    // back what it was told. Zero is the default and means "untagged", for a
    // caller with one request in flight and nothing to disambiguate.
    void get(const QString &path, quint64 token = 0);

    // PATCH `path` with `body` as JSON, ending in replied() or failed() with
    // `token` handed back, exactly as get() does.
    //
    // The one write this local API takes, and it lives here rather than in a
    // backend for the reason every read does: it is the same exchange, one
    // socket and one response, and the deadline below is the whole reason
    // nothing else may open a socket of its own.
    //
    // A REFUSAL IS AN ORDINARY OUTCOME HERE, not a sign tailscaled is gone.
    // It authorises writes by peer credentials -- root, or the one user named
    // as its operator -- and answers anyone else 403 while serving that same
    // user's reads perfectly. A caller that treats a failed write like a
    // failed read publishes "no daemon" for what is a permission setting.
    void patch(const QString &path, const QByteArray &body, quint64 token = 0);

    // Stream /localapi/v0/watch-ipn-bus: one event() per complete line, then
    // watchEnded() when the stream stops.
    void watch();

    // Drop everything in flight, the watch included. Emits nothing.
    void stop();

signals:
    // The response body, headers stripped, and the token its get() carried.
    void replied(const QString &path, const QByteArray &body, quint64 token);
    // Why a request ended badly, and the token its get() carried. A watch that
    // fails emits this first and watchEnded straight after, never one without
    // the other; a watch carries no token of its own and reports zero.
    //
    // `reason` is the sentence -- what a caller publishes for someone to read.
    // The two after it are the same ending made DECIDABLE, because the two
    // decisions a caller has to make cannot be made from a sentence without
    // matching strings against it:
    //
    //   * `status` is the HTTP status tailscaled answered with, or 0 when it
    //     never answered one. A 403 is a permission setting and nothing else
    //     -- it says the caller is not this daemon's operator, while the same
    //     socket serves the same process's reads perfectly -- and a caller
    //     that cannot tell it from a timeout reports a transient as a
    //     permanent refusal.
    //   * `socketAbsent` is true only for ServerNotFoundError: there is
    //     nothing at the socket path at all, which is the one failure that
    //     means Tailscale is not installed here rather than unreadable. Every
    //     other transport error -- refused, access denied, closed -- is a
    //     daemon that IS there and could not be read, and those are opposite
    //     things to show a person.
    void failed(const QString &path, const QString &reason, quint64 token, int status = 0,
                bool socketAbsent = false);
    // The watch's response headers arrived and were accepted: the stream is
    // up and notifications will follow. Emitted once per watch, before any
    // event(), and never for a get.
    //
    // It exists because nothing else says the stream is established. A caller
    // that waits for the first event() to decide a watch is working waits on
    // tailscaled's habit of sending an opening notification, and a quiet bus
    // may send nothing for hours.
    void watchStarted();
    // One complete notification. Never a partial line: a line split across two
    // reads is held until the newline arrives.
    //
    // Deliberately untokened, with watchEnded and watchStarted: the watch is
    // one long-lived stream rather than a round of asking, so there is no
    // round for a notification to belong to. A notification is what makes a
    // caller START a round.
    void event(const QByteArray &line);
    void watchEnded();

private:
    struct Exchange {
        QString path;
        // Handed back on this exchange's replied() or failed(), untouched.
        quint64 token = 0;
        QByteArray buffer; // read, not yet unframed
        QByteArray body;   // unframed payload
        bool streaming = false;
        bool headersDone = false;
        bool chunked = false;
        bool ended = false; // the zero-length chunk closed the body
        qsizetype contentLength = -1;
        // -1 awaiting a chunk-size line, 0 the CRLF that closes a chunk's
        // data, above that the bytes of this chunk still to come.
        qsizetype chunkLeft = -1;
        // Ends this exchange in fail() if it gets there. Disarmed by take(),
        // and for a watch by its headers being accepted -- after that the
        // stream is established and is allowed to be quiet.
        QTimer *deadline = nullptr;
    };

    void start(const QByteArray &method, const QString &path, const QByteArray &body,
               bool streaming, quint64 token);
    void read(QLocalSocket *socket);
    // Headers, framing, delivery -- each step able to end the exchange, after
    // which the ones behind it do nothing.
    void deliver(QLocalSocket *socket);
    bool readHeaders(QLocalSocket *socket);
    bool unframe(QLocalSocket *socket);
    void emitLines(QLocalSocket *socket);
    void closed(QLocalSocket *socket);
    void errored(QLocalSocket *socket);
    void finish(QLocalSocket *socket);
    // `status` and `socketAbsent` are handed to failed() unchanged -- see the
    // signal for what a caller decides with them.
    void fail(QLocalSocket *socket, const QString &reason, int status = 0,
              bool socketAbsent = false);
    // Stop and drop `exchange`'s deadline, if it still has one. Called with
    // the exchange already out of the table, so a timeout cannot race the
    // ending that disarmed it.
    static void disarm(Exchange &exchange);
    // Forget `socket` and hand back what it was doing, once: whoever takes an
    // exchange owns the ending, so no response is reported twice.
    std::optional<Exchange> take(QLocalSocket *socket);

    QString m_socketPath;
    int m_timeoutMs;
    QHash<QLocalSocket *, Exchange> m_exchanges;
};

} // namespace c7::tailscale
