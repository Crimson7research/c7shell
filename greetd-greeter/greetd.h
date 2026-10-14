// greetd's IPC, as a QObject the QML can talk to.
//
// The protocol is a conversation by construction: greetd sends auth_message
// (typed visible/secret/info/error) and waits for post_auth_message_response.
// Nothing is ever answered on the greeter's behalf, which is the whole reason
// we are here -- a mistyped PIN is one attempt, not a replay loop, and a second
// question (enrol a PIN, change a password) reaches the user.
//
// Framing is a 32-bit native-endian length followed by UTF-8 JSON.
#pragma once

#include <QJsonObject>
#include <QLocalSocket>
#include <QObject>
#include <QStringList>

class GreetdClient : public QObject
{
    Q_OBJECT
public:
    explicit GreetdClient(QObject *parent = nullptr);

    bool connectToDaemon();

public Q_SLOTS:
    void createSession(const QString &username);
    void respond(const QString &response);
    // Acknowledge an informational message. greetd-ipc(7): every auth_message
    // "must be answered with either post_auth_message_response or
    // cancel_session"; for info and error the response field is simply
    // omitted. Without this the conversation stops at the first info message.
    void acknowledge();
    void startSession(const QStringList &cmd);
    void cancelSession();

Q_SIGNALS:
    // type is one of "visible", "secret", "info", "error".
    void authMessage(const QString &text, const QString &type);
    void authSuccess();
    void authError(const QString &description);
    // start_session was accepted. greetd-ipc(7): "the session will start after
    // the greeter process terminates" -- so this is the cue to exit, and until
    // we do, greetd is just waiting on us.
    void sessionStarted();

private:
    void send(const QJsonObject &payload);
    void onReadyRead();

    QLocalSocket m_sock;
    QByteArray m_buf;
    // greetd answers every request with exactly one reply, and "success" is a
    // generic acknowledgement rather than a statement about authentication.
    // cancel_session, start_session and a completed login all come back as
    // "success", so the only way to read a reply is to remember what was
    // asked. Without this the ack for start_session looks like a second
    // successful login and we start the session twice -- the second attempt
    // failing with "no session active".
    QStringList m_inflight;
};
