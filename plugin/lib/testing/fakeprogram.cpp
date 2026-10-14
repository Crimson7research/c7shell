#include "testing/fakeprogram.h"

#include <QtCore/QDir>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>

namespace c7::testing {

namespace fp = fakeprogram;

FakeProgram::FakeProgram(const QString &name) : m_name(name)
{
    if (!m_dir.isValid()) {
        fail(m_dir.errorString());
        return;
    }
    for (const char *sub : {"bin", "state/replies", "state/calls"}) {
        if (!QDir().mkpath(m_dir.filePath(QLatin1String(sub)))) {
            fail(QStringLiteral("cannot create %1").arg(QLatin1String(sub)));
            return;
        }
    }
    // A link, not a copy: c7-fake-program reads its directory from this path.
    if (!QFile::link(QStringLiteral(C7_FAKE_PROGRAM_BIN), path()))
        fail(QStringLiteral("cannot link %1 to %2").arg(path(), QStringLiteral(C7_FAKE_PROGRAM_BIN)));
}

QString FakeProgram::path() const
{
    return binDir() + QLatin1Char('/') + m_name;
}

QString FakeProgram::binDir() const
{
    return m_dir.filePath(QStringLiteral("bin"));
}

QString FakeProgram::stateDir() const
{
    return m_dir.filePath(QStringLiteral("state"));
}

void FakeProgram::fail(const QString &why) const
{
    if (m_error.isEmpty())
        m_error = why;
}

void FakeProgram::reply(const QByteArray &out, const QByteArray &err, int exitCode)
{
    const int k = ++m_replies;
    if (exitCode < 0 || exitCode > 255 || exitCode == fp::kBroken || exitCode == fp::kUnscripted) {
        fail(QStringLiteral("reply %1: exit code %2 is not 0..255, or is the fake's own 126 or 127")
                 .arg(k)
                 .arg(exitCode));
        return;
    }
    const QString dir = QStringLiteral("%1/%2/%3").arg(stateDir(), QLatin1String(fp::kReplies)).arg(k);
    // The code last: c7-fake-program takes a reply to exist once its code does.
    if (!QDir().mkpath(dir) || !fp::writeFile(dir + QLatin1Char('/') + QLatin1String(fp::kOut), out)
        || !fp::writeFile(dir + QLatin1Char('/') + QLatin1String(fp::kErr), err)
        || !fp::writeFile(dir + QLatin1Char('/') + QLatin1String(fp::kCode), QByteArray::number(exitCode)))
        fail(QStringLiteral("cannot write reply %1 in %2").arg(k).arg(dir));
}

void FakeProgram::readStdin(bool on)
{
    const QString flag = stateDir() + QLatin1Char('/') + QLatin1String(fp::kReadStdin);
    if (on ? !fp::writeFile(flag, {}) : (QFile::exists(flag) && !QFile::remove(flag)))
        fail(QStringLiteral("cannot set %1").arg(flag));
}

QList<FakeProgram::Run> FakeProgram::runs() const
{
    QList<Run> out;
    const QString dir = stateDir() + QLatin1Char('/') + QLatin1String(fp::kCalls);
    for (int n = 1;; ++n) {
        QByteArray json;
        if (!fp::readFile(QStringLiteral("%1/%2.json").arg(dir).arg(n), &json))
            return out;
        QJsonParseError err{};
        const QJsonObject run = QJsonDocument::fromJson(json, &err).object();
        if (err.error != QJsonParseError::NoError) {
            fail(QStringLiteral("cannot read the record of run %1: %2").arg(n).arg(err.errorString()));
            return out;
        }
        Run r;
        for (const QJsonValue &a : run.value(QLatin1String("argv")).toArray())
            r.argv << a.toString();
        r.stdinData = QByteArray::fromBase64(run.value(QLatin1String("stdin")).toString().toLatin1());
        out << r;
    }
}

QList<QStringList> FakeProgram::calls() const
{
    QList<QStringList> out;
    for (const Run &r : runs())
        out << r.argv;
    return out;
}

QByteArrayList FakeProgram::stdins() const
{
    QByteArrayList out;
    for (const Run &r : runs())
        out << r.stdinData;
    return out;
}

int FakeProgram::unusedReplies() const
{
    return std::max(0, m_replies - int(runs().size()));
}

} // namespace c7::testing
