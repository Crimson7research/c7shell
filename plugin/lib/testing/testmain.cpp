#include "testing/testmain.h"

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QProcessEnvironment>
#include <QtCore/QTemporaryDir>

#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace c7::testing {

namespace {

// Lives until the process exits, then takes the directory with it. Made on the
// first call, under the host's TMPDIR, before isolation replaces it.
QTemporaryDir &root()
{
    static QTemporaryDir dir(QDir::tempPath() + QStringLiteral("/c7-test-XXXXXX"));
    return dir;
}

[[noreturn]] void refuse(const QString &why)
{
    std::fprintf(stderr, "c7 test: cannot isolate from the host: %s\n", qPrintable(why));
    std::exit(2);
}

// Each variable isolation points into the private directory, and where.
struct Private {
    const char *var;
    const char *sub;
};
constexpr Private kPrivate[] = {
    {"HOME", "home"},
    {"XDG_RUNTIME_DIR", "runtime"},
    {"XDG_CONFIG_HOME", "config"},
    {"XDG_DATA_HOME", "data"},
    {"XDG_CACHE_HOME", "cache"},
    {"XDG_STATE_HOME", "state"},
    {"XDG_CONFIG_DIRS", "config-dirs"},
    {"XDG_DATA_DIRS", "data-dirs"},
    {"TMPDIR", "tmp"},
    // Empty: a bare program name finds nothing. Tests name their fakes by path.
    {"PATH", "bin"},
};

bool kept(const QString &name)
{
    const QStringList keeps = isolationKeeps();
    return std::any_of(keeps.cbegin(), keeps.cend(), [&](const QString &k) {
        return k.endsWith(QLatin1Char('*')) ? name.startsWith(k.chopped(1)) : name == k;
    });
}

} // namespace

QStringList isolationKeeps()
{
    return {QStringLiteral("LANG"),           QStringLiteral("LANGUAGE"),
            QStringLiteral("LC_*"),           QStringLiteral("TERM"),
            QStringLiteral("QT_LOGGING_RULES"), QStringLiteral("QT_MESSAGE_PATTERN"),
            QStringLiteral("QT_FORCE_STDERR_LOGGING"), QStringLiteral("QTEST_*"),
            QStringLiteral("LLVM_PROFILE_FILE"), QStringLiteral("GCOV_*"),
            QStringLiteral("ASAN_*"),         QStringLiteral("UBSAN_*"),
            QStringLiteral("LSAN_*"),         QStringLiteral("TSAN_*"),
            // Set by ctest and tests/test-c7-plugin.sh: which copy of C7 tst_module loads.
            QStringLiteral("C7_QML_IMPORT_PATH")};
}

QStringList isolationSets()
{
    QStringList out{QStringLiteral("DBUS_SESSION_BUS_ADDRESS"), QStringLiteral("DBUS_SYSTEM_BUS_ADDRESS")};
    for (const Private &p : kPrivate)
        out << QLatin1String(p.var);
    return out;
}

void isolateFromHost()
{
    QTemporaryDir &dir = root();
    if (!dir.isValid())
        refuse(dir.errorString());
    const QString base = dir.path();

    for (const QString &name : QProcessEnvironment::systemEnvironment().keys()) {
        if (!kept(name))
            qunsetenv(name.toLocal8Bit().constData());
    }

    const QByteArray dead = QStringLiteral("unix:path=%1/no-such-bus").arg(base).toLocal8Bit();
    qputenv("DBUS_SESSION_BUS_ADDRESS", dead);
    qputenv("DBUS_SYSTEM_BUS_ADDRESS", dead);
    for (const Private &p : kPrivate) {
        const QString path = base + QLatin1Char('/') + QLatin1String(p.sub);
        if (!QDir().mkpath(path))
            refuse(QStringLiteral("cannot create %1").arg(path));
        qputenv(p.var, path.toLocal8Bit());
    }
    // Qt warns about, and some programs refuse, a runtime directory others can read.
    if (!QFile::setPermissions(base + QStringLiteral("/runtime"),
                               QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner))
        refuse(QStringLiteral("cannot make the runtime directory private"));
}

QString hostIsolationRoot()
{
    return root().path();
}

} // namespace c7::testing
