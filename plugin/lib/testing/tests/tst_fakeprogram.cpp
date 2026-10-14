#include "testing/fakeprogram.h"
#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtCore/QFile>
#include <QtCore/QFileInfo>
#include <QtCore/QProcess>
#include <QtCore/QSet>
#include <QtTest/QTest>

#include <optional>

using c7::testing::FakeProgram;
using c7::testing::waitUntil;

namespace {

// How a library under test runs a program: async QProcess, no waitFor*.
struct Run {
    QByteArray out;
    QByteArray err;
    int exitCode = -1;
};

// The finished run; nullopt when it never started or never finished.
std::optional<Run> run(QProcess &proc, const QString &program, const QStringList &args,
                       const QByteArray &input = {})
{
    proc.start(program, args);
    if (!waitUntil([&] { return proc.state() != QProcess::Starting; }) || proc.state() != QProcess::Running)
        return std::nullopt;
    if (!input.isNull()) {
        proc.write(input);
        proc.closeWriteChannel();
    }
    if (!waitUntil([&] { return proc.state() == QProcess::NotRunning; })
        || proc.exitStatus() != QProcess::NormalExit)
        return std::nullopt;
    return Run{proc.readAllStandardOutput(), proc.readAllStandardError(), proc.exitCode()};
}

std::optional<Run> run(const QString &program, const QStringList &args, const QByteArray &input = {})
{
    QProcess proc;
    return run(proc, program, args, input);
}

} // namespace

class TestFakeProgram : public QObject {
    Q_OBJECT

private slots:
    void isNamedLikeTheProgramItStandsIn()
    {
        FakeProgram nmcli(QStringLiteral("nmcli"));
        QVERIFY2(nmcli.isValid(), qPrintable(nmcli.error()));
        QCOMPARE(QFileInfo(nmcli.path()).fileName(), QStringLiteral("nmcli"));
        QVERIFY(QFileInfo(nmcli.path()).isExecutable());
    }

    void recordsArgvAndPlaysBackTheReply()
    {
        FakeProgram nmcli(QStringLiteral("nmcli"));
        nmcli.reply("enabled\n", "warning\n", 3);
        QVERIFY2(nmcli.isValid(), qPrintable(nmcli.error()));
        const auto r = run(nmcli.path(), {QStringLiteral("radio"), QStringLiteral("wifi")});
        QVERIFY(r);
        QCOMPARE(r->out, QByteArray("enabled\n"));
        QCOMPARE(r->err, QByteArray("warning\n"));
        QCOMPARE(r->exitCode, 3);
        QCOMPARE(nmcli.calls(), (QList<QStringList>{{QStringLiteral("radio"), QStringLiteral("wifi")}}));
        QCOMPARE(nmcli.unusedReplies(), 0);
        QVERIFY(nmcli.isValid());
    }

    void keepsArgumentsExactly()
    {
        FakeProgram p(QStringLiteral("grim"));
        p.reply({});
        const QStringList args{QStringLiteral("-g"), QStringLiteral("10,20 30x40"),
                               QString(), QStringLiteral("ünï\tcode")};
        QVERIFY(run(p.path(), args));
        QCOMPARE(p.calls(), QList<QStringList>{args});
    }

    void replyNumberKAnswersRunNumberK()
    {
        FakeProgram p(QStringLiteral("hyprctl"));
        p.reply("first");
        p.reply("second", {}, 1);
        QCOMPARE(p.unusedReplies(), 2);
        QCOMPARE(run(p.path(), {QStringLiteral("a")}).value().out, QByteArray("first"));
        const auto second = run(p.path(), {QStringLiteral("b")});
        QVERIFY(second);
        QCOMPARE(second->out, QByteArray("second"));
        QCOMPARE(second->exitCode, 1);
        QCOMPARE(p.calls().size(), 2);
        QCOMPARE(p.unusedReplies(), 0);
    }

    void saysWhichRepliesNobodyUsed()
    {
        // A library that never ran the program must not pass on a reply nobody read.
        FakeProgram p(QStringLiteral("systemctl"));
        p.reply("ok");
        p.reply("ok");
        QVERIFY(run(p.path(), {}));
        QCOMPARE(p.unusedReplies(), 1);
    }

    void failsACallNobodyScripted()
    {
        FakeProgram p(QStringLiteral("rfkill"));
        const auto r = run(p.path(), {QStringLiteral("list")});
        QVERIFY(r);
        QCOMPARE(r->exitCode, 127);
        QVERIFY(r->err.contains("no reply scripted for call 1"));
        QCOMPARE(p.calls().size(), 1);
    }

    void refusesAnExitCodeAProcessCannotHave_data()
    {
        QTest::addColumn<int>("code");
        QTest::newRow("256 wraps to 0") << 256;
        QTest::newRow("negative") << -1;
        QTest::newRow("the fixture's own 126") << 126;
        QTest::newRow("the fixture's own 127") << 127;
    }

    void refusesAnExitCodeAProcessCannotHave()
    {
        QFETCH(int, code);
        FakeProgram p(QStringLiteral("nmcli"));
        p.reply({}, {}, code);
        QVERIFY(!p.isValid());
        QVERIFY2(p.error().contains(QString::number(code)), qPrintable(p.error()));
    }

    void acceptsTheWholeRangeOfExitCodes()
    {
        FakeProgram p(QStringLiteral("nmcli"));
        p.reply({}, {}, 0);
        p.reply({}, {}, 255);
        QVERIFY2(p.isValid(), qPrintable(p.error()));
        QCOMPARE(run(p.path(), {}).value().exitCode, 0);
        QCOMPARE(run(p.path(), {}).value().exitCode, 255);
    }

    void capturesStandardInputOnlyWhenAsked()
    {
        FakeProgram p(QStringLiteral("nmcli"));
        p.readStdin(true);
        p.reply({});
        p.reply({});
        QVERIFY(run(p.path(), {QStringLiteral("--ask")}, "s3cret\n"));
        p.readStdin(false);
        QVERIFY(run(p.path(), {}, "ignored\n"));
        QVERIFY2(p.isValid(), qPrintable(p.error()));
        QCOMPARE(p.stdins(), (QByteArrayList{"s3cret\n", ""}));
    }

    void numbersRunsThatStartTogether()
    {
        // Libraries start programs side by side; every run gets its own number
        // and its own reply.
        constexpr int n = 12;
        FakeProgram p(QStringLiteral("nmcli"));
        for (int i = 1; i <= n; ++i)
            p.reply(QByteArray::number(i));
        std::vector<std::unique_ptr<QProcess>> procs;
        for (int i = 0; i < n; ++i) {
            procs.push_back(std::make_unique<QProcess>());
            procs.back()->start(p.path(), {QString::number(i)});
        }
        QVERIFY(waitUntil([&] {
            return std::all_of(procs.cbegin(), procs.cend(),
                               [](const auto &q) { return q->state() == QProcess::NotRunning; });
        }));
        QSet<QByteArray> outs;
        for (const auto &q : procs) {
            QCOMPARE(q->exitCode(), 0);
            outs << q->readAllStandardOutput();
        }
        QCOMPARE(outs.size(), n);
        QCOMPARE(p.calls().size(), n);
        QCOMPARE(p.unusedReplies(), 0);
    }

    void reportsARecordItCannotRead()
    {
        FakeProgram p(QStringLiteral("nmcli"));
        QFile torn(p.stateDir() + QStringLiteral("/calls/1.json"));
        QVERIFY(torn.open(QIODevice::WriteOnly));
        torn.write("{\"argv\": [\"ha");
        torn.close();
        p.calls();
        QVERIFY(!p.isValid());
        QVERIFY2(p.error().contains(QLatin1String("run 1")), qPrintable(p.error()));
    }

    void isFoundOnPath()
    {
        // QProcess looks a bare name up on this process's PATH, so that is the
        // one a test puts the fake on, as it would for a library under test.
        FakeProgram p(QStringLiteral("playerctl"));
        p.reply("Playing\n");
        const QByteArray saved = qgetenv("PATH");
        qputenv("PATH", p.binDir().toLocal8Bit() + ':' + saved);
        const auto r = run(QStringLiteral("playerctl"), {QStringLiteral("status")});
        qputenv("PATH", saved);
        QVERIFY(r);
        QCOMPARE(r->out, QByteArray("Playing\n"));
        QCOMPARE(p.calls(), QList<QStringList>{{QStringLiteral("status")}});
    }

    void needsNoEnvironment()
    {
        FakeProgram p(QStringLiteral("wpctl"));
        p.reply("ok");
        QProcess proc;
        proc.setProcessEnvironment(QProcessEnvironment());
        const auto r = run(proc, p.path(), {});
        QVERIFY(r);
        QCOMPARE(r->out, QByteArray("ok"));
        QCOMPARE(p.calls().size(), 1);
    }

    void twoFakesKeepSeparateRecords()
    {
        FakeProgram a(QStringLiteral("nmcli"));
        FakeProgram b(QStringLiteral("nmcli"));
        a.reply("a");
        b.reply("b");
        QCOMPARE(run(a.path(), {}).value().out, QByteArray("a"));
        QCOMPARE(run(b.path(), {}).value().out, QByteArray("b"));
        QCOMPARE(a.calls().size(), 1);
        QCOMPARE(b.calls().size(), 1);
    }
};

C7_TEST_MAIN(TestFakeProgram)
#include "tst_fakeprogram.moc"
