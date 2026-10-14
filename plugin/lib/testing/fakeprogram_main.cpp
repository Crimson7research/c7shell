// c7-fake-program: what a FakeProgram puts on disk as <dir>/bin/<name>. Records
// the run and plays back the scripted reply; see fakeprogram.h for the files.
#include "testing/fakeprogram.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDir>
#include <QtCore/QFileInfo>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QStandardPaths>

#include <cstdio>
#include <optional>
#include <sys/file.h>

namespace fp = c7::testing::fakeprogram;

namespace {

int die(int code, const QString &why)
{
    std::fprintf(stderr, "c7-fake-program: %s\n", qPrintable(why));
    return code;
}

// <dir>/state, from the path this run was started as. Started by bare name, it
// was found on PATH; the link's directory, not its target's, is the one wanted.
QString stateDir(const QString &argv0)
{
    const QString self = argv0.contains(QLatin1Char('/')) ? argv0
                                                          : QStandardPaths::findExecutable(argv0);
    if (self.isEmpty())
        return {};
    return QFileInfo(self).absoluteDir().absoluteFilePath(QStringLiteral("../state"));
}

QString file(const QString &dir, const char *name)
{
    return dir + QLatin1Char('/') + QLatin1String(name);
}

// Record this run and return its number; nullopt (and a message) on failure.
// The number is taken under the lock, so runs started together never share
// one, and the record appears whole: written aside, then renamed into place.
// flock(), not QLockFile: QLockFile polls with growing sleeps, so a dozen runs
// started together could wait longer than a test's bound; flock() wakes the
// next waiter the moment the lock is free. The kernel drops it when we exit.
std::optional<int> recordRun(const QString &state, const QStringList &args, const QByteArray &input)
{
    QFile lockFile(file(state, fp::kLock));
    if (!lockFile.open(QIODevice::WriteOnly) || ::flock(lockFile.handle(), LOCK_EX) != 0) {
        die(fp::kBroken, QStringLiteral("cannot lock %1").arg(lockFile.fileName()));
        return std::nullopt;
    }
    const QString calls = file(state, fp::kCalls);
    int n = 1;
    while (QFileInfo::exists(QStringLiteral("%1/%2.json").arg(calls).arg(n)))
        ++n;
    const QJsonObject run{{QStringLiteral("argv"), QJsonArray::fromStringList(args)},
                          {QStringLiteral("stdin"), QString::fromLatin1(input.toBase64())}};
    const QString final = QStringLiteral("%1/%2.json").arg(calls).arg(n);
    const QString aside = final + QStringLiteral(".tmp");
    if (!fp::writeFile(aside, QJsonDocument(run).toJson(QJsonDocument::Compact))
        || !QFile::rename(aside, final)) {
        die(fp::kBroken, QStringLiteral("cannot record the run in %1").arg(final));
        return std::nullopt;
    }
    return n;
}

bool writeAll(FILE *to, const QByteArray &data)
{
    return std::fwrite(data.constData(), 1, size_t(data.size()), to) == size_t(data.size())
           && std::fflush(to) == 0;
}

// Play back the reply to run n; its exit code is the process's.
int playBack(const QString &state, int n)
{
    const QString reply = QStringLiteral("%1/%2").arg(file(state, fp::kReplies)).arg(n);
    QByteArray code;
    if (!fp::readFile(file(reply, fp::kCode), &code))
        return die(fp::kUnscripted, QStringLiteral("no reply scripted for call %1").arg(n));
    QByteArray out;
    QByteArray err;
    if (!fp::readFile(file(reply, fp::kOut), &out) || !fp::readFile(file(reply, fp::kErr), &err))
        return die(fp::kBroken, QStringLiteral("reply %1 is incomplete").arg(n));
    if (!writeAll(stdout, out) || !writeAll(stderr, err))
        return fp::kBroken;
    return code.toInt();
}

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication app(argc, argv);
    QStringList args = app.arguments();
    const QString state = stateDir(args.takeFirst());
    if (state.isEmpty() || !QFileInfo(state).isDir())
        return die(fp::kBroken, QStringLiteral("cannot find my state directory (run as %1)")
                                    .arg(QString::fromLocal8Bit(argv[0])));

    QByteArray input;
    if (QFileInfo::exists(file(state, fp::kReadStdin))) {
        QFile in;
        if (!in.open(stdin, QIODevice::ReadOnly))
            return die(fp::kBroken, QStringLiteral("cannot read standard input"));
        input = in.readAll();
    }
    const std::optional<int> n = recordRun(state, args, input);
    return n ? playBack(state, *n) : fp::kBroken;
}
