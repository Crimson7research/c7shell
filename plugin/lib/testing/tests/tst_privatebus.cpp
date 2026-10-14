#include "testing/fakeprogram.h"
#include "testing/privatebus.h"
#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtCore/QProcess>
#include <QtDBus/QDBusConnection>
#include <QtDBus/QDBusConnectionInterface>
#include <QtTest/QTest>

#include <cerrno>
#include <csignal>

using c7::testing::FakeProgram;
using c7::testing::PrivateBus;
using c7::testing::waitUntil;

namespace {

// The process is gone: not running, and not a zombie waiting to be reaped.
bool processIsGone(qint64 pid)
{
    return ::kill(pid_t(pid), 0) != 0 && errno == ESRCH;
}

} // namespace

class TestPrivateBus : public QObject {
    Q_OBJECT

private slots:
    void startsAndHandsOutConnections()
    {
        PrivateBus bus;
        QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
        QVERIFY(bus.address().startsWith(QLatin1String("unix:")));
        QVERIFY(bus.pid() > 0);
        QDBusConnection c = bus.connect();
        QVERIFY2(c.isConnected(), qPrintable(c.lastError().message()));
        QVERIFY(!c.baseService().isEmpty());
    }

    void eachConnectionIsItsOwnPeer()
    {
        PrivateBus bus;
        QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
        QVERIFY(bus.connect().baseService() != bus.connect().baseService());
    }

    void twoBusesShareNothing()
    {
        PrivateBus a;
        PrivateBus b;
        QVERIFY2(a.isRunning() && b.isRunning(), qPrintable(a.error() + b.error()));
        QVERIFY(a.address() != b.address());

        const QString name = QStringLiteral("org.c7.Test.Shared");
        QDBusConnection ca = a.connect();
        QDBusConnection cb = b.connect();
        QVERIFY(ca.registerService(name));
        QVERIFY(ca.interface()->isServiceRegistered(name));
        QVERIFY(!cb.interface()->isServiceRegistered(name));
        // Free on b, so b can take it too.
        QVERIFY(cb.registerService(name));
    }

    void startsASystemBus()
    {
        PrivateBus bus(PrivateBus::Kind::System);
        QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
        QVERIFY(bus.connect().isConnected());
    }

    void stopsTheDaemonWithTheFixture()
    {
        qint64 pid = 0;
        QDBusConnection kept(QString{});
        {
            PrivateBus bus;
            QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
            pid = bus.pid();
            kept = bus.connect();
            QVERIFY(kept.isConnected());
        }
        QVERIFY(processIsGone(pid));
        // A connection hears that its bus went away asynchronously.
        QVERIFY(waitUntil([&] { return !kept.isConnected(); }));
    }

    void stopsTheDaemonWhenTheTestCrashes()
    {
        // A test that aborts never runs a destructor; the daemon still goes.
        QProcess crash;
        crash.start(QStringLiteral(C7_PRIVATEBUS_CRASH_BIN), {});
        QVERIFY(waitUntil([&] { return crash.state() == QProcess::NotRunning; }));
        QCOMPARE(crash.exitStatus(), QProcess::CrashExit);
        bool ok = false;
        const qint64 pid = crash.readAllStandardOutput().trimmed().toLongLong(&ok);
        QVERIFY2(ok && pid > 0, crash.readAllStandardError().constData());
        QVERIFY(waitUntil([&] { return processIsGone(pid); }));
    }

    void notesADaemonThatDied()
    {
        PrivateBus bus;
        QVERIFY2(bus.isRunning(), qPrintable(bus.error()));
        ::kill(pid_t(bus.pid()), SIGKILL);
        QVERIFY(waitUntil([&] { return !bus.isRunning(); }));
    }

    void reportsADaemonThatWillNotStart()
    {
        PrivateBus bus(PrivateBus::Kind::Session, QStringLiteral("/nonexistent/dbus-daemon"));
        QVERIFY(!bus.isRunning());
        QVERIFY(!bus.error().isEmpty());
        QVERIFY(!bus.connect().isConnected());
    }

    void reportsADaemonThatPrintsNoAddress()
    {
        FakeProgram daemon(QStringLiteral("dbus-daemon"));
        daemon.reply("tcp:host=localhost,port=1\n");
        QVERIFY2(daemon.isValid(), qPrintable(daemon.error()));
        PrivateBus bus(PrivateBus::Kind::Session, daemon.path());
        QVERIFY(!bus.isRunning());
        QVERIFY2(bus.error().contains(QLatin1String("no address")), qPrintable(bus.error()));
    }
};

C7_TEST_MAIN(TestPrivateBus)
#include "tst_privatebus.moc"
