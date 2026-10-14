#include "testing/privatebus.h"

#include "testing/wait.h"

#include <QtCore/QFile>

#include <csignal>
#include <sys/prctl.h>
#include <unistd.h>

namespace c7::testing {

namespace {

// No <servicedir> and no <standard_*_servicedirs/>: the only thing on this bus
// is what the test puts there (the same shape as tests/test-filechooser.sh's).
QByteArray config(PrivateBus::Kind kind, const QString &dir)
{
    const QByteArray type = kind == PrivateBus::Kind::System ? "system" : "session";
    return "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN\"\n"
           " \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n"
           "<busconfig>\n"
           "  <type>" + type + "</type>\n"
           "  <listen>unix:dir=" + dir.toUtf8() + "</listen>\n"
           "  <auth>EXTERNAL</auth>\n"
           "  <policy context=\"default\">\n"
           "    <allow own=\"*\"/>\n"
           "    <allow send_type=\"method_call\"/>\n"
           "    <allow send_type=\"signal\"/>\n"
           "    <allow send_type=\"method_return\"/>\n"
           "    <allow send_type=\"error\"/>\n"
           "    <allow receive_type=\"method_call\"/>\n"
           "    <allow receive_type=\"signal\"/>\n"
           "    <allow receive_type=\"method_return\"/>\n"
           "    <allow receive_type=\"error\"/>\n"
           "  </policy>\n"
           "</busconfig>\n";
}

const int kBoundMs = int(kWaitBound.count());

} // namespace

PrivateBus::PrivateBus(Kind kind, const QString &daemon)
{
    start(kind, daemon.isEmpty() ? QStringLiteral(C7_DBUS_DAEMON) : daemon);
}

void PrivateBus::start(Kind kind, const QString &daemon)
{
    if (!m_dir.isValid()) {
        m_error = QStringLiteral("no temporary directory: %1").arg(m_dir.errorString());
        return;
    }
    QFile conf(m_dir.filePath(QStringLiteral("bus.conf")));
    if (!conf.open(QIODevice::WriteOnly) || conf.write(config(kind, m_dir.path())) < 0) {
        m_error = QStringLiteral("cannot write %1: %2").arg(conf.fileName(), conf.errorString());
        return;
    }
    conf.close();

    // A test that dies runs no destructor, so the kernel kills the daemon with
    // it. Linux only, like everything this kit fakes. If the test died between
    // fork and prctl, the parent is already someone else: go now. The signal
    // follows the thread that started the daemon, so make a PrivateBus on the
    // test's main thread.
    const pid_t parent = ::getpid();
    m_daemon.setChildProcessModifier([parent] {
        if (::prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || ::getppid() != parent)
            ::_exit(1);
    });
    // A fixture may block where library code may not: the test cannot go on
    // until the bus exists.
    m_daemon.start(daemon, {QStringLiteral("--config-file=") + conf.fileName(),
                            QStringLiteral("--print-address=1"), QStringLiteral("--nofork"),
                            QStringLiteral("--nopidfile"), QStringLiteral("--nosyslog")});
    if (!m_daemon.waitForStarted(kBoundMs)) {
        m_error = QStringLiteral("%1 did not start: %2").arg(daemon, m_daemon.errorString());
        return;
    }
    QByteArray out;
    while (!out.contains('\n') && m_daemon.state() == QProcess::Running
           && m_daemon.waitForReadyRead(kBoundMs))
        out += m_daemon.readAllStandardOutput();
    out += m_daemon.readAllStandardOutput();
    const QString address = QString::fromUtf8(out).section(QLatin1Char('\n'), 0, 0).trimmed();
    if (!address.startsWith(QLatin1String("unix:"))) {
        m_error = QStringLiteral("%1 printed no address; stderr: %2")
                      .arg(daemon, QString::fromLocal8Bit(m_daemon.readAllStandardError()));
        return;
    }
    m_address = address;
}

PrivateBus::~PrivateBus()
{
    for (const QString &name : std::as_const(m_connections))
        QDBusConnection::disconnectFromBus(name);
    if (m_daemon.state() != QProcess::NotRunning) {
        m_daemon.terminate();
        if (!m_daemon.waitForFinished(kBoundMs)) {
            m_daemon.kill();
            m_daemon.waitForFinished(kBoundMs);
        }
    }
}

QDBusConnection PrivateBus::connect()
{
    if (!isRunning())
        return QDBusConnection(QString());
    const QString name = QStringLiteral("c7-private-bus-%1-%2")
                             .arg(quintptr(this), 0, 16)
                             .arg(m_connections.size());
    m_connections << name;
    return QDBusConnection::connectToBus(m_address, name);
}

} // namespace c7::testing
