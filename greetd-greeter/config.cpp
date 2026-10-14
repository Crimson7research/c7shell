#include "config.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSettings>
#include <QTextStream>

ThemeConfig::ThemeConfig(const QString &path, QObject *parent) : QObject(parent)
{
    if (!QFileInfo::exists(path))
        return;
    QSettings s(path, QSettings::IniFormat);
    s.beginGroup(QStringLiteral("General"));
    const QString bg = s.value(QStringLiteral("background")).toString();
    // Empty means the generated backdrop, which is the design's default.
    if (!bg.isEmpty())
        m_wallpaper = QUrl::fromLocalFile(bg);
    m_showGrid = s.value(QStringLiteral("grid"), true).toString() != QLatin1String("false");
    m_allowManualLogin =
        s.value(QStringLiteral("allowManualLogin"), true).toString() != QLatin1String("false");
    m_userList = s.value(QStringLiteral("userList"), QStringLiteral("auto")).toString();
    m_maxAttempts = s.value(QStringLiteral("maxAttempts"), 3).toInt();
    m_cooldownSeconds = s.value(QStringLiteral("cooldownSeconds"), 30).toInt();
    m_loginOnAllScreens =
        s.value(QStringLiteral("loginOnAllScreens"), false).toString() == QLatin1String("true");
    if (m_maxAttempts < 1) m_maxAttempts = 3;
    if (m_cooldownSeconds < 0) m_cooldownSeconds = 30;
}

LastUserStore::LastUserStore(const QString &path, QObject *parent)
    : QObject(parent), m_path(path)
{
    QFile f(m_path);
    if (f.open(QIODevice::ReadOnly | QIODevice::Text))
        m_lastUser = QTextStream(&f).readLine().trimmed();
}

void LastUserStore::remember(const QString &user)
{
    if (user.isEmpty())
        return;
    QFile f(m_path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        return;   // not fatal: the greeter simply will not preselect next time
    QTextStream(&f) << user << '\n';
}

KeyboardState::KeyboardState(QObject *parent) : QObject(parent)
{
    // Any keyboard's LED will do; they are kept in sync by the kernel.
    const QDir leds(QStringLiteral("/sys/class/leds"));
    for (const QString &name : leds.entryList({QStringLiteral("*capslock*")}, QDir::Dirs)) {
        m_ledPath = leds.filePath(name) + QStringLiteral("/brightness");
        break;
    }

    // The configured console layouts, for the layout indicator. Switching them
    // is not possible here: under cage the keymap is the compositor's, and it
    // offers no protocol to change it.
    QFile vc(QStringLiteral("/etc/vconsole.conf"));
    if (vc.open(QIODevice::ReadOnly | QIODevice::Text)) {
        QTextStream in(&vc);
        while (!in.atEnd()) {
            const QString line = in.readLine().trimmed();
            if (line.startsWith(QStringLiteral("KEYMAP="))) {
                QString v = line.mid(7);
                v.remove(QLatin1Char('"'));
                if (!v.isEmpty())
                    m_layouts << QVariantMap{{QStringLiteral("shortName"), v}};
            }
        }
    }
    if (m_layouts.isEmpty())
        m_layouts << QVariantMap{{QStringLiteral("shortName"), QStringLiteral("us")}};

    // eDP/LVDS/DSI are the internal-panel connector types.
    const QDir drm(QStringLiteral("/sys/class/drm"));
    for (const QString &name : drm.entryList({QStringLiteral("card*-eDP-*"),
                                              QStringLiteral("card*-LVDS-*"),
                                              QStringLiteral("card*-DSI-*")}, QDir::Dirs)) {
        QFile st(drm.filePath(name) + QStringLiteral("/status"));
        if (!st.open(QIODevice::ReadOnly | QIODevice::Text))
            continue;
        if (st.readAll().trimmed() != "connected")
            continue;
        // card1-eDP-1 -> eDP-1, which is what wayland reports as the output
        // name. section(..., 1) alone would stop at the first field and give
        // "eDP"; the trailing -1 takes everything from there to the end.
        m_internalOutput = name.section(QLatin1Char('-'), 1, -1);
        break;
    }

    if (!m_ledPath.isEmpty()) {
        connect(&m_timer, &QTimer::timeout, this, &KeyboardState::poll);
        m_timer.start(250);
        poll();
    }
}

void KeyboardState::poll()
{
    QFile f(m_ledPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return;
    const bool on = f.readAll().trimmed().toInt() != 0;
    if (on != m_capsLock) {
        m_capsLock = on;
        Q_EMIT capsLockChanged();
    }
}
