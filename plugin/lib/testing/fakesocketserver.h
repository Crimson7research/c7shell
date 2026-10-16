#pragma once

#include <QtCore/QByteArrayList>
#include <QtCore/QHash>
#include <QtCore/QList>
#include <QtCore/QObject>
#include <QtCore/QPointer>
#include <QtNetwork/QLocalServer>

#include <functional>

class QLocalSocket;

namespace c7::testing {

// A Unix socket server at a path the test chooses, standing in for one a
// program c7shell talks to: Hyprland's request socket (write a command, read
// the reply, the server closes) and its event socket (the server pushes lines),
// hyprsunset's, hyprpaper's. Removed when the fixture goes; its clients are
// disconnected then, which is how a test plays the program exiting.
//
// It refuses a path that already exists rather than take it over, so it never
// removes a socket another server is using.
class FakeSocketServer : public QObject {
    Q_OBJECT

public:
    using Handler = std::function<QByteArray(const QByteArray &request)>;
    enum AfterReply { CloseAfterReply, KeepOpen };

    explicit FakeSocketServer(const QString &path, QObject *parent = nullptr);
    ~FakeSocketServer() override;

    bool isListening() const { return m_server.isListening(); }
    QString error() const { return m_error; }
    QString path() const { return m_path; }

    // Answer every request with `handler`'s reply; by default close the client
    // after it. Without a handler a request is recorded and left unanswered.
    //
    // A stream keeps no write boundaries. With a `delimiter`, a request is what
    // comes before each delimiter, however the bytes arrive; bytes left without
    // one when the client goes are not a request, so a client that forgets the
    // delimiter shows as a missing request, never a partial one. Without one, a
    // request is whatever one read returns, which is how Hyprland's request
    // socket reads; use that only where the client writes once and waits.
    //
    // With a delimiter, a request that declares a `Content-Length` also takes
    // that many bytes from behind the delimiter, and is not a request until
    // all of them have arrived. That is HTTP, whose delimiter ends its
    // HEADERS and not its message: without this a PATCH is recorded with its
    // body missing, and the body is then read as the start of the next
    // request. Nothing else sends that header, so nothing else is affected.
    void onRequest(Handler handler, AfterReply after = CloseAfterReply, const QByteArray &delimiter = {});

    // Withhold the reply to the next request whose text contains `fragment`:
    // the request is recorded as usual, the handler does not run for it, and
    // the client is left connected and silent. That is a request IN FLIGHT --
    // made, and not yet answered -- which a test otherwise has no way to hold
    // still.
    //
    // A held client is also skipped by pushLine() and pushChunk(), and that is
    // the half worth spelling out: a push at a half-answered request lands in
    // that request's body, not on the stream the test meant. A notification
    // pushed while a status read was held used to be read as the status
    // reply, which failed the read and quietly took the backend down -- so
    // the test that was pinning "nothing is re-read while a refresh is out"
    // was really pinning "nothing is re-read once the backend has given up".
    //
    // One at a time, and armed again for each hold.
    void holdNext(const QByteArray &fragment);
    // Write `reply` to every held client and release them; returns how many.
    int completeHeld(const QByteArray &reply);
    int heldCount() const { return int(m_held.size()); }

    // Send `line` and a newline to every connected client that is not held;
    // returns how many.
    int pushLine(const QByteArray &line);

    // Send exactly `bytes` -- no newline added -- to every connected client
    // that is not held; returns how many. What pushLine is built on, and what a test uses to
    // split one line across two sends: a stream keeps no write boundaries, so
    // a client that reads lines must cope with half of one arriving alone.
    int pushChunk(const QByteArray &bytes);

    // Every request received, in order.
    QByteArrayList requests() const { return m_requests; }
    int clientCount() const { return m_clients.size(); }

private:
    void accept();
    void read(QLocalSocket *client);
    void answer(QLocalSocket *client, const QByteArray &request);

    QLocalServer m_server;
    QString m_path;
    QString m_error;
    Handler m_handler;
    AfterReply m_after = CloseAfterReply;
    QByteArray m_delimiter;
    // Write to `clients`, skipping anything gone; returns how many took it.
    int writeTo(const QList<QPointer<QLocalSocket>> &clients, const QByteArray &bytes);

    QByteArrayList m_requests;
    QList<QPointer<QLocalSocket>> m_clients;
    QByteArray m_holdFragment;
    QList<QPointer<QLocalSocket>> m_held;
    QHash<QLocalSocket *, QByteArray> m_pending;
};

} // namespace c7::testing
