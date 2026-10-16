#include "models.h"

#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>

#include <pwd.h>

namespace {
// The window sddm compiles in (UID_MAX=60513) is far below a directory
// backend's hashed uids -- Himmelblau's range is 200000-2000200000 -- which is
// why Entra accounts never reached sddm's list. Ours is wide enough to include
// them, and the shell filter keeps the system accounts out.
constexpr quint32 kMinUid = 1000;
constexpr quint32 kMaxUid = 2000200000;

bool isLoginShell(const QString &shell)
{
    static const QStringList nope = {
        "/usr/bin/nologin", "/sbin/nologin", "/usr/sbin/nologin",
        "/bin/false", "/usr/bin/false",
    };
    return !shell.isEmpty() && !nope.contains(shell);
}
} // namespace

UsersModel::UsersModel(QObject *parent) : QAbstractListModel(parent)
{
    setpwent();
    while (struct passwd *pw = getpwent()) {
        const quint32 uid = pw->pw_uid;
        if (uid < kMinUid || uid > kMaxUid)
            continue;
        const QString shell = QString::fromLocal8Bit(pw->pw_shell);
        if (!isLoginShell(shell))
            continue;
        User u;
        u.name = QString::fromLocal8Bit(pw->pw_name);
        u.realName = QString::fromLocal8Bit(pw->pw_gecos).section(QLatin1Char(','), 0, 0);
        u.uid = uid;
        // Where AccountsService keeps avatars, and where a directory backend
        // drops the photo it fetched.
        const QString icon = QStringLiteral("/var/lib/AccountsService/icons/%1").arg(u.name);
        if (QFileInfo::exists(icon))
            u.icon = QStringLiteral("file://") + icon;
        m_users.append(u);
    }
    endpwent();
    std::sort(m_users.begin(), m_users.end(),
              [](const User &a, const User &b) { return a.name < b.name; });
}

int UsersModel::rowCount(const QModelIndex &) const { return m_users.size(); }

QVariant UsersModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_users.size())
        return {};
    const User &u = m_users.at(index.row());
    switch (role) {
    case NameRole: return u.name;
    case RealNameRole: return u.realName;
    case IconRole: return u.icon;
    case UidRole: return u.uid;
    }
    return {};
}

QHash<int, QByteArray> UsersModel::roleNames() const
{
    return {{NameRole, "name"}, {RealNameRole, "realName"},
            {IconRole, "icon"}, {UidRole, "uid"}};
}

SessionsModel::SessionsModel(QObject *parent) : QAbstractListModel(parent)
{
    for (const QString &dir : {QStringLiteral("/usr/share/wayland-sessions"),
                               QStringLiteral("/usr/share/xsessions")}) {
        const QDir d(dir);
        for (const QFileInfo &fi : d.entryInfoList({QStringLiteral("*.desktop")}, QDir::Files)) {
            QSettings s(fi.absoluteFilePath(), QSettings::IniFormat);
            s.beginGroup(QStringLiteral("Desktop Entry"));
            if (s.value(QStringLiteral("Hidden")).toBool())
                continue;
            Session sess;
            sess.name = s.value(QStringLiteral("Name")).toString();
            sess.comment = s.value(QStringLiteral("Comment")).toString();
            sess.exec = s.value(QStringLiteral("Exec")).toString();
            if (!sess.name.isEmpty() && !sess.exec.isEmpty())
                m_sessions.append(sess);
        }
    }
}

int SessionsModel::rowCount(const QModelIndex &) const { return m_sessions.size(); }

QVariant SessionsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_sessions.size())
        return {};
    const Session &s = m_sessions.at(index.row());
    switch (role) {
    case NameRole: return s.name;
    case CommentRole: return s.comment;
    case ExecRole: return s.exec;
    }
    return {};
}

QHash<int, QByteArray> SessionsModel::roleNames() const
{
    return {{NameRole, "name"}, {CommentRole, "comment"}, {ExecRole, "exec"}};
}

QString SessionsModel::execAt(int row) const
{
    return (row >= 0 && row < m_sessions.size()) ? m_sessions.at(row).exec : QString();
}

PowerInterface::PowerInterface(QObject *parent) : QObject(parent) {}

QString PowerInterface::probe(const QString &method) const
{
    QDBusInterface login1(QStringLiteral("org.freedesktop.login1"),
                          QStringLiteral("/org/freedesktop/login1"),
                          QStringLiteral("org.freedesktop.login1.Manager"),
                          QDBusConnection::systemBus());
    const QDBusReply<QString> r = login1.call(method);
    return r.isValid() ? r.value() : QString();
}

void PowerInterface::call(const QString &method)
{
    QDBusInterface login1(QStringLiteral("org.freedesktop.login1"),
                          QStringLiteral("/org/freedesktop/login1"),
                          QStringLiteral("org.freedesktop.login1.Manager"),
                          QDBusConnection::systemBus());
    login1.call(method, true /* interactive */);
}

bool PowerInterface::canSuspend() const { return probe(QStringLiteral("CanSuspend")) == QLatin1String("yes"); }
bool PowerInterface::canReboot() const { return probe(QStringLiteral("CanReboot")) == QLatin1String("yes"); }
bool PowerInterface::canPowerOff() const { return probe(QStringLiteral("CanPowerOff")) == QLatin1String("yes"); }

void PowerInterface::suspend() { call(QStringLiteral("Suspend")); }
void PowerInterface::reboot() { call(QStringLiteral("Reboot")); }
void PowerInterface::powerOff() { call(QStringLiteral("PowerOff")); }
