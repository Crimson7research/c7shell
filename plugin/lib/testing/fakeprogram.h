#pragma once

#include <QtCore/QByteArrayList>
#include <QtCore/QFile>
#include <QtCore/QList>
#include <QtCore/QStringList>
#include <QtCore/QTemporaryDir>

namespace c7::testing {

// The files FakeProgram and c7-fake-program share, under <dir>/state:
//   replies/<n>/{out,err,code}   the reply to run n, counted from 1
//   calls/<n>.json               run n: {"argv": [...], "stdin": base64};
//                                written whole (temporary file, then rename)
//   read-stdin                   present: every run reads stdin to its end
//   lock                         serialises runs that start together
// c7-fake-program finds <dir> from its own path, <dir>/bin/<name>, so it needs
// no environment.
namespace fakeprogram {
inline constexpr char kReplies[] = "replies";
inline constexpr char kCalls[] = "calls";
inline constexpr char kReadStdin[] = "read-stdin";
inline constexpr char kLock[] = "lock";
inline constexpr char kOut[] = "out";
inline constexpr char kErr[] = "err";
inline constexpr char kCode[] = "code";
// Exit codes the fake keeps for itself: it could not run, and nobody scripted
// this run. A reply may not use them, so the two never look alike.
inline constexpr int kBroken = 126;
inline constexpr int kUnscripted = 127;

inline bool writeFile(const QString &path, const QByteArray &data)
{
    QFile f(path);
    return f.open(QIODevice::WriteOnly) && f.write(data) == data.size();
}

inline bool readFile(const QString &path, QByteArray *data)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return false;
    *data = f.readAll();
    return true;
}
} // namespace fakeprogram

// A program a library under test runs, in place of the real one (nmcli, grim,
// hyprctl). path() is an executable named like that program; hand it to the
// library, or put binDir() first on its PATH. Each run records its argv (and,
// if asked, its standard input) and plays back its reply. The library's own
// QProcess code runs unchanged.
//
// A run nobody scripted a reply for exits 127 and says so on stderr, so a test
// that forgot one fails instead of passing on an empty answer.
class FakeProgram {
public:
    explicit FakeProgram(const QString &name);

    FakeProgram(const FakeProgram &) = delete;
    FakeProgram &operator=(const FakeProgram &) = delete;

    // Nothing has gone wrong with the fixture itself: it was set up, every
    // reply was written, and every record read back. A test asserts this when
    // a fixture problem would otherwise look like a library bug.
    bool isValid() const { return m_error.isEmpty(); }
    QString error() const { return m_error; }

    QString path() const;
    QString binDir() const;
    // Where the files above live; for tests of the fixture itself.
    QString stateDir() const;

    // The k-th call scripts the reply to run k: stdout, stderr and an exit code
    // in 0..255 other than 126 and 127.
    void reply(const QByteArray &out, const QByteArray &err = {}, int exitCode = 0);
    // From the next run on, read standard input to its end and record it.
    void readStdin(bool on);

    // The arguments of each run, without argv[0], in the order they ran.
    QList<QStringList> calls() const;
    // What each run read on standard input; empty unless readStdin(true).
    QByteArrayList stdins() const;
    // Replies scripted that no run has used yet. A test checks this is 0 when
    // it expects the library to have run the program.
    int unusedReplies() const;

private:
    struct Run {
        QStringList argv;
        QByteArray stdinData;
    };
    QList<Run> runs() const;
    void fail(const QString &why) const;

    QTemporaryDir m_dir;
    QString m_name;
    mutable QString m_error;
    int m_replies = 0;
};

} // namespace c7::testing
