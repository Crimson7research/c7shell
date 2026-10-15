#include "core/version.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QFileInfo>
#include <QtCore/QMetaObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QStringList>
#include <QtQml/QQmlEngine>
#include "testing/testmain.h"

#include <QtTest/QTest>

namespace {

// `import C7` resolves from one module directory alone, the way the shell finds
// the installed one. That directory is the build tree's (C7_QML_IMPORT_PATH,
// compiled in), or an installed tree named by the variable of the same name.
// It is the only import path, so no other copy of C7 can stand in for it. That
// also rules out `import QtQml`, so these tests read a singleton from C++
// rather than through a QML document.
QString importPath()
{
    return qEnvironmentVariable("C7_QML_IMPORT_PATH", QStringLiteral(C7_QML_IMPORT_PATH));
}

// The engine stays the caller's, because a singleton belongs to the engine
// that made it and must not outlive it.
QObject *singleton(QQmlEngine &engine, const char *name)
{
    engine.setImportPathList({importPath()});
    return engine.singletonInstance<QObject *>("C7", name);
}

// Every property `obj` declares beyond QObject's own, sorted. QObject
// contributes objectName to every class, and it is not part of any contract.
QStringList declaredProperties(const QObject *obj)
{
    const QMetaObject *meta = obj->metaObject();
    QStringList names;
    for (int i = QObject::staticMetaObject.propertyCount(); i < meta->propertyCount(); ++i)
        names << QString::fromUtf8(meta->property(i).name());
    names.sort();
    return names;
}

} // namespace

class TestModule : public QObject {
    Q_OBJECT

private slots:
    // One slot per singleton, and the module directory checked once here. Qt
    // reports nothing when a singleton fails to resolve, so each slot can then
    // blame the plugin rather than the import path -- and a run with no module
    // installed fails exactly once, whatever the module has grown to hold.
    void initTestCase()
    {
        QVERIFY2(QFileInfo::exists(importPath() + QStringLiteral("/C7/qmldir")),
                 "module C7 is not installed: no C7/qmldir under the import path");
    }

    void buildSingletonReportsTheLibraryVersion()
    {
        QQmlEngine engine;
        QObject *build = singleton(engine, "Build");
        QVERIFY2(build, "C7/qmldir exists, but its plugin or Build singleton did not load");
        QCOMPARE(build->property("version").toString(), c7::core::version());
    }

    // The starting state, pinned: the singleton loads, opens the socket
    // TS_SOCKET names -- which isolation points at a path in a private
    // directory that nothing listens on -- and reads as a machine that has
    // not reported in rather than as one that is connected and unblocked.
    //
    // Read after a bounded wait, not synchronously. The constructor's requests
    // go out through the event loop, so a `state` read in the same block is
    // read before any reply could have arrived and would pass just as well
    // against a backend that published Running a millisecond later. The wait
    // is how a negative is proved; it is the shape every other test in this
    // tree uses for one, and a passing run never waits longer than this.
    void tailscaleSingletonLoadsAndStaysInNoState()
    {
        QVERIFY2(qEnvironmentVariable("TS_SOCKET")
                         .startsWith(c7::testing::hostIsolationRoot() + QLatin1Char('/')),
                 "TS_SOCKET does not point into the isolation root: this test would open the "
                 "host's own tailscaled socket");
        QQmlEngine engine;
        QObject *ts = singleton(engine, "Tailscale");
        QVERIFY2(ts, "module C7 loaded but its Tailscale singleton did not");
        QCOMPARE(ts->property("state").toInt(), 0); // State::NoState
        QVERIFY(ts->property("peers").value<QAbstractItemModel *>() != nullptr);
        QVERIFY(ts->property("exitNodes").value<QAbstractItemModel *>() != nullptr);
        QTest::qWait(250);
        QCOMPARE(ts->property("state").toInt(), 0);
        QCOMPARE(ts->property("exitNodeBlocked").toBool(), false);
        QCOMPARE(ts->property("peers").value<QAbstractItemModel *>()->rowCount(), 0);
    }

    // The whole contract, not a sample of it. tests/test-tailscale.sh writes a
    // QML stand-in for this singleton and checks it against the same header;
    // this is the other end of that -- what the header declares and what the
    // built module exposes are the same set, so a Q_PROPERTY renamed, dropped
    // or added cannot pass unremarked at either end.
    void tailscaleSingletonExposesExactlyTheContract()
    {
        QQmlEngine engine;
        QObject *ts = singleton(engine, "Tailscale");
        QVERIFY2(ts, "module C7 loaded but its Tailscale singleton did not");
        QStringList expected{
            QStringLiteral("state"),           QStringLiteral("selfName"),
            QStringLiteral("selfIp4"),         QStringLiteral("selfIp6"),
            QStringLiteral("selfDnsName"),     QStringLiteral("tailnet"),
            QStringLiteral("keyExpiry"),       QStringLiteral("exitNodeActive"),
            QStringLiteral("exitNodeId"),      QStringLiteral("exitNodeName"),
            QStringLiteral("exitNodeOnline"),  QStringLiteral("exitNodeBlocked"),
            QStringLiteral("issues"),          QStringLiteral("issueCount"),
            QStringLiteral("peers"),           QStringLiteral("exitNodes"),
            QStringLiteral("recommendedExitNodeId")};
        expected.sort();
        QCOMPARE(declaredProperties(ts), expected);
    }
};

C7_TEST_MAIN(TestModule)
#include "tst_module.moc"
