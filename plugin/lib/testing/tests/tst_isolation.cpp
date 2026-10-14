#include "testing/privatebus.h"
#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QProcess>
#include <QtCore/QProcessEnvironment>
#include <QtDBus/QDBusConnection>
#include <QtTest/QTest>

using c7::testing::hostIsolationRoot;
using c7::testing::isolateFromHost;

namespace {

// Each case plants a host variable, isolates again and checks it is gone, so
// the result never depends on what the machine running the test has set.
void plantAndIsolate(const char *var, const QByteArray &value)
{
    qputenv(var, value);
    isolateFromHost();
}

bool isPrivate(const QString &path)
{
    return path.startsWith(hostIsolationRoot() + QLatin1Char('/'));
}

} // namespace

// C7_TEST_MAIN cuts the test off from the host before anything runs, so a
// library or fixture that reaches for the real buses, sockets, directories or
// programs fails instead of quietly using the machine's.
class TestIsolation : public QObject {
    Q_OBJECT

private slots:
    void theHostSessionBusIsUnreachable() { QVERIFY(!QDBusConnection::sessionBus().isConnected()); }

    void theHostSystemBusIsUnreachable() { QVERIFY(!QDBusConnection::systemBus().isConnected()); }

    void busAddressesPointNowhere_data()
    {
        QTest::addColumn<QByteArray>("var");
        QTest::newRow("session") << QByteArray("DBUS_SESSION_BUS_ADDRESS");
        QTest::newRow("system") << QByteArray("DBUS_SYSTEM_BUS_ADDRESS");
    }

    void busAddressesPointNowhere()
    {
        QFETCH(QByteArray, var);
        // A live bus, so a fixture that kept the variable would leave it reachable.
        c7::testing::PrivateBus live;
        QVERIFY2(live.isRunning(), qPrintable(live.error()));
        plantAndIsolate(var.constData(), live.address().toUtf8());
        const QString now = qEnvironmentVariable(var.constData());
        QVERIFY2(now != live.address(), qPrintable(now));
        QVERIFY2(now.contains(hostIsolationRoot()), qPrintable(now));
    }

    void directoriesArePrivate_data()
    {
        QTest::addColumn<QByteArray>("var");
        for (const char *v : {"XDG_RUNTIME_DIR", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                              "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_CONFIG_DIRS", "XDG_DATA_DIRS",
                              "TMPDIR"})
            QTest::newRow(v) << QByteArray(v);
    }

    void directoriesArePrivate()
    {
        QFETCH(QByteArray, var);
        plantAndIsolate(var.constData(), "/run/user/1000");
        const QString dir = qEnvironmentVariable(var.constData());
        QVERIFY2(isPrivate(dir), qPrintable(QStringLiteral("%1=%2").arg(QString::fromLatin1(var), dir)));
        QVERIFY(QFileInfo(dir).isDir());
        QVERIFY(QFileInfo(dir).isWritable());
    }

    void theRootAndTheRuntimeDirectoryArePrivate_data()
    {
        QTest::addColumn<QString>("dir");
        QTest::newRow("root") << hostIsolationRoot();
        QTest::newRow("runtime") << qEnvironmentVariable("XDG_RUNTIME_DIR");
    }

    void theRootAndTheRuntimeDirectoryArePrivate()
    {
        QFETCH(QString, dir);
        const QFile::Permissions others = QFile::ReadGroup | QFile::WriteGroup | QFile::ExeGroup
                                          | QFile::ReadOther | QFile::WriteOther | QFile::ExeOther;
        QCOMPARE(QFileInfo(dir).permissions() & others, QFile::Permissions{});
    }

    void hostVariablesAreDropped_data()
    {
        QTest::addColumn<QByteArray>("var");
        for (const char *v :
             {"HYPRLAND_INSTANCE_SIGNATURE", "HYPRLAND_CMD", "WAYLAND_DISPLAY", "WAYLAND_SOCKET",
              "DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP",
              "DESKTOP_SESSION", "XDG_SEAT", "XDG_SESSION_PATH", "DBUS_STARTER_ADDRESS",
              "DBUS_STARTER_BUS_TYPE", "PIPEWIRE_RUNTIME_DIR", "PIPEWIRE_REMOTE", "PULSE_SERVER",
              "AT_SPI_BUS_ADDRESS", "SSH_AUTH_SOCK", "C7_SOMETHING_NEW"})
            QTest::newRow(v) << QByteArray(v);
    }

    void hostVariablesAreDropped()
    {
        QFETCH(QByteArray, var);
        plantAndIsolate(var.constData(), "host-value");
        QVERIFY2(!qEnvironmentVariableIsSet(var.constData()), var.constData());
    }

    void allowedVariablesAreKept_data()
    {
        // One per allowlist entry shape: an exact name and each kind of prefix.
        // Coverage and sanitizers read GCOV_*, LLVM_PROFILE_FILE and ASAN_*.
        QTest::addColumn<QByteArray>("var");
        for (const char *v : {"LANG", "LC_C7TEST", "QTEST_C7TEST", "GCOV_PREFIX", "LLVM_PROFILE_FILE",
                              "ASAN_OPTIONS", "QT_LOGGING_RULES", "C7_QML_IMPORT_PATH"})
            QTest::newRow(v) << QByteArray(v);
    }

    void allowedVariablesAreKept()
    {
        QFETCH(QByteArray, var);
        const QByteArray saved = qgetenv(var.constData());
        const bool wasSet = qEnvironmentVariableIsSet(var.constData());
        plantAndIsolate(var.constData(), "kept");
        const QByteArray now = qgetenv(var.constData());
        if (wasSet)
            qputenv(var.constData(), saved);
        else
            qunsetenv(var.constData());
        QCOMPARE(now, QByteArray("kept"));
    }

    void onlyAllowedVariablesSurvive()
    {
        isolateFromHost();
        const QStringList kept = c7::testing::isolationKeeps();
        const QStringList set = c7::testing::isolationSets();
        for (const QString &name : QProcessEnvironment::systemEnvironment().keys()) {
            const bool allowed = set.contains(name)
                                 || std::any_of(kept.cbegin(), kept.cend(), [&](const QString &k) {
                                        return k.endsWith(QLatin1Char('*'))
                                                   ? name.startsWith(k.chopped(1))
                                                   : name == k;
                                    });
            QVERIFY2(allowed, qPrintable(name));
        }
    }

    void hostProgramsAreNotOnPath()
    {
        // A library test that forgot its FakeProgram must not run the real one.
        QVERIFY(isPrivate(qEnvironmentVariable("PATH")));
        QProcess proc;
        proc.start(QStringLiteral("sh"), {QStringLiteral("-c"), QStringLiteral("true")});
        QVERIFY(c7::testing::waitUntil([&] { return proc.state() == QProcess::NotRunning; }));
        QCOMPARE(proc.error(), QProcess::FailedToStart);
    }

    void aPrivateBusStillWorks()
    {
        c7::testing::PrivateBus bus;
        QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
        QVERIFY(bus.connect().isConnected());
    }
};

C7_TEST_MAIN(TestIsolation)
#include "tst_isolation.moc"
