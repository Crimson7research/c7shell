// The three things a display manager normally hands a greeter. greetd does not:
// its protocol is only the authentication conversation, so the user list, the
// session list and the power actions are ours to supply.
#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QStringList>

class UsersModel : public QAbstractListModel
{
    Q_OBJECT
    // QAbstractListModel exposes rowCount() but no `count` property, and the
    // QML asks for users.count.
    Q_PROPERTY(int count READ count CONSTANT)
public:
    int count() const { return rowCount(); }
    enum Roles { NameRole = Qt::UserRole + 1, RealNameRole, IconRole, UidRole };

    explicit UsersModel(QObject *parent = nullptr);
    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

private:
    struct User { QString name, realName, icon; quint32 uid; };
    QList<User> m_users;
};

class SessionsModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count CONSTANT)
public:
    int count() const { return rowCount(); }
    enum Roles { NameRole = Qt::UserRole + 1, CommentRole, ExecRole };

    explicit SessionsModel(QObject *parent = nullptr);
    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    Q_INVOKABLE QString execAt(int row) const;

private:
    struct Session { QString name, comment, exec; };
    QList<Session> m_sessions;
};

class PowerInterface : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool canSuspend READ canSuspend CONSTANT)
    Q_PROPERTY(bool canReboot READ canReboot CONSTANT)
    Q_PROPERTY(bool canPowerOff READ canPowerOff CONSTANT)
public:
    explicit PowerInterface(QObject *parent = nullptr);

    bool canSuspend() const;
    bool canReboot() const;
    bool canPowerOff() const;

public Q_SLOTS:
    void suspend();
    void reboot();
    void powerOff();

private:
    QString probe(const QString &method) const;
    void call(const QString &method);
};
