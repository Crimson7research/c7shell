#include "greetd.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QStringList>
#include <QtEndian>
#include <QDebug>

namespace {
// Tracing the protocol is the only way to see what PAM asked for and whether
// we answered, which is how every bug in this client was found. It is off
// unless C7_GREETER_DEBUG is set: a greeter should not narrate itself into the
// system log on every login.
bool tracing()
{
    static const bool on = !qEnvironmentVariableIsEmpty("C7_GREETER_DEBUG");
    return on;
}
} // namespace

GreetdClient::GreetdClient(QObject *parent) : QObject(parent)
{
    connect(&m_sock, &QLocalSocket::readyRead, this, &GreetdClient::onReadyRead);
}

bool GreetdClient::connectToDaemon()
{
    const QByteArray path = qgetenv("GREETD_SOCK");
    if (path.isEmpty()) {
        qCritical("GREETD_SOCK is not set; not running under greetd");
        return false;
    }
    m_sock.connectToServer(QString::fromLocal8Bit(path));
    if (!m_sock.waitForConnected(5000)) {
        qCritical("cannot connect to %s: %s", path.constData(),
                  qPrintable(m_sock.errorString()));
        return false;
    }
    return true;
}

void GreetdClient::send(const QJsonObject &payload)
{
    const QString type = payload.value("type").toString();
    m_inflight.append(type);
    const QByteArray json = QJsonDocument(payload).toJson(QJsonDocument::Compact);
    // The secret never reaches the log: only the message type is printed.
    if (tracing())
        qInfo("greetd <- %s", type.toUtf8().constData());
    // Native byte order, per greetd-ipc(7).
    const quint32 len = static_cast<quint32>(json.size());
    m_sock.write(reinterpret_cast<const char *>(&len), sizeof(len));
    m_sock.write(json);
    m_sock.flush();
}

void GreetdClient::createSession(const QString &username)
{
    send({{"type", "create_session"}, {"username", username}});
}

void GreetdClient::respond(const QString &response)
{
    send({{"type", "post_auth_message_response"}, {"response", response}});
}

void GreetdClient::acknowledge()
{
    send({{"type", "post_auth_message_response"}});
}

void GreetdClient::startSession(const QStringList &cmd)
{
    send({{"type", "start_session"},
          {"cmd", QJsonArray::fromStringList(cmd)},
          {"env", QJsonArray()}});
}

void GreetdClient::cancelSession()
{
    send({{"type", "cancel_session"}});
}

void GreetdClient::onReadyRead()
{
    m_buf.append(m_sock.readAll());
    for (;;) {
        if (m_buf.size() < int(sizeof(quint32)))
            return;
        quint32 len = 0;
        memcpy(&len, m_buf.constData(), sizeof(len));
        if (m_buf.size() < int(sizeof(len) + len))
            return;
        const QByteArray json = m_buf.mid(sizeof(len), len);
        m_buf.remove(0, sizeof(len) + len);

        const QJsonObject o = QJsonDocument::fromJson(json).object();
        const QString type = o.value("type").toString();
        if (tracing())
            qInfo("greetd -> %s%s", type.toUtf8().constData(),
              type == QLatin1String("auth_message")
                  ? QByteArray(" [" + o.value("auth_message_type").toString().toUtf8()
                               + "] " + o.value("auth_message").toString().toUtf8()).constData()
              : type == QLatin1String("error")
                  ? QByteArray(" " + o.value("description").toString().toUtf8()).constData()
                  : "");
        // Every reply answers exactly one request; pair them up.
        const QString request = m_inflight.isEmpty() ? QString() : m_inflight.takeFirst();

        if (type == QLatin1String("auth_message")) {
            Q_EMIT authMessage(o.value("auth_message").toString(),
                               o.value("auth_message_type").toString());
        } else if (type == QLatin1String("success")) {
            // Only create_session and post_auth_message_response can report a
            // completed authentication. The acks for cancel_session and
            // start_session say nothing about the user.
            if (request == QLatin1String("create_session")
                || request == QLatin1String("post_auth_message_response")) {
                Q_EMIT authSuccess();
            } else if (request == QLatin1String("start_session")) {
                Q_EMIT sessionStarted();
            }
        } else if (type == QLatin1String("error")) {
            // Cancelling when nothing is in flight is not a login failure.
            if (request != QLatin1String("cancel_session"))
                Q_EMIT authError(o.value("description").toString());
        }
    }
}
