// theme.conf and the remembered account.
//
// sddm gave a theme both of these: it parsed theme.conf into a `config` object
// and kept the last account in /var/lib/sddm/state.conf. greetd has no notion
// of either -- it is only an authentication protocol -- so the greeter keeps
// them itself, reading the same theme.conf the sddm theme uses so one file
// serves both.
#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
#include <QUrl>

class ThemeConfig : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QUrl wallpaper READ wallpaper CONSTANT)
    Q_PROPERTY(bool showGrid READ showGrid CONSTANT)
    Q_PROPERTY(bool allowManualLogin READ allowManualLogin CONSTANT)
    Q_PROPERTY(QString userList READ userList CONSTANT)
    Q_PROPERTY(int maxAttempts READ maxAttempts CONSTANT)
    Q_PROPERTY(int cooldownSeconds READ cooldownSeconds CONSTANT)
    Q_PROPERTY(bool loginOnAllScreens READ loginOnAllScreens CONSTANT)
public:
    explicit ThemeConfig(const QString &path, QObject *parent = nullptr);

    QUrl wallpaper() const { return m_wallpaper; }
    bool showGrid() const { return m_showGrid; }
    bool allowManualLogin() const { return m_allowManualLogin; }
    QString userList() const { return m_userList; }
    int maxAttempts() const { return m_maxAttempts; }
    int cooldownSeconds() const { return m_cooldownSeconds; }
    bool loginOnAllScreens() const { return m_loginOnAllScreens; }

private:
    QUrl m_wallpaper;
    bool m_showGrid = true;
    bool m_allowManualLogin = true;
    QString m_userList = QStringLiteral("auto");
    int m_maxAttempts = 3;
    int m_cooldownSeconds = 30;
    bool m_loginOnAllScreens = false;
};

// The account that logged in last, so logging out returns you to yourself.
class LastUserStore : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString lastUser READ lastUser CONSTANT)
public:
    explicit LastUserStore(const QString &path, QObject *parent = nullptr);

    QString lastUser() const { return m_lastUser; }
    Q_INVOKABLE void remember(const QString &user);

private:
    QString m_path;
    QString m_lastUser;
};

// Caps lock, and which keyboard layouts the console is configured for.
//
// Under a wayland compositor the keymap belongs to the compositor, and Qt
// exposes no modifier state to a client that has no focused key event. The
// kernel does though: the caps lock LED is a file. Polling it is unglamorous
// and completely reliable, including when caps was left on before the greeter
// started.
class KeyboardState : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool capsLock READ capsLock NOTIFY capsLockChanged)
    // The theme reads .shortName off each entry, so these are objects rather
    // than plain strings.
    Q_PROPERTY(QVariantList layouts READ layouts CONSTANT)
    // The internal panel's connector name (eDP-1, LVDS-1, DSI-1...), or empty
    // on a machine that has none. The card belongs there rather than on
    // whichever output the compositor happens to enumerate first.
    Q_PROPERTY(QString internalOutput READ internalOutput CONSTANT)
public:
    explicit KeyboardState(QObject *parent = nullptr);

    bool capsLock() const { return m_capsLock; }
    QVariantList layouts() const { return m_layouts; }
    QString internalOutput() const { return m_internalOutput; }

Q_SIGNALS:
    void capsLockChanged();

private:
    void poll();

    QString m_ledPath;
    bool m_capsLock = false;
    QVariantList m_layouts;
    QString m_internalOutput;
    QTimer m_timer;
};
