#include "tailscale/StatusParser.h"

#include "testing/testmain.h"

#include <QtCore/QFile>
#include <QtTest/QTest>

using c7::tailscale::StatusParser;

namespace {

QByteArray readFixture(const char *name)
{
    QFile f(QStringLiteral(C7_FIXTURE_DIR "/") + QLatin1String(name));
    // An unreadable fixture must fail the test, not parse as "malformed".
    if (!f.open(QIODevice::ReadOnly))
        qFatal("cannot open fixture %s", name);
    return f.readAll();
}

} // namespace

class TestStatusParser : public QObject {
    Q_OBJECT

private slots:
    void parsesBackendStateAndHealth()
    {
        const auto s = StatusParser::parse(readFixture("status-idle.json"));
        QVERIFY(s.has_value());
        QCOMPARE(s->backendState, QStringLiteral("Running"));
        QCOMPARE(s->health.size(), 1);
        QVERIFY(s->health.first().contains(QStringLiteral("--accept-routes")));
        QCOMPARE(s->selfIp4, QStringLiteral("100.73.10.20"));
        QCOMPARE(s->tailnet, QStringLiteral("example.com"));
    }

    void rejectsMalformedJson()
    {
        QVERIFY(!StatusParser::parse(QByteArrayLiteral("{\"Self\":")).has_value());
        QVERIFY(!StatusParser::parse(QByteArray()).has_value());
    }
};

C7_TEST_MAIN(TestStatusParser)
#include "tst_statusparser.moc"
