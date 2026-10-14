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
    void onRequest(Handler handler, AfterReply after = CloseAfterReply, const QByteArray &delimiter = {});

    // Send `line` and a newline to every connected client; returns how many.
    int pushLine(const QByteArray &line);

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
    QByteArrayList m_requests;
    QList<QPointer<QLocalSocket>> m_clients;
    QHash<QLocalSocket *, QByteArray> m_pending;
};

} // namespace c7::testing
