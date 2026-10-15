#include "core/version.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QFileInfo>
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
        engine.setImportPathList({importPath()});
        auto *build = engine.singletonInstance<QObject *>("C7", "Build");
        QVERIFY2(build, "C7/qmldir exists, but its plugin or Build singleton did not load");
        QCOMPARE(build->property("version").toString(), c7::core::version());
    }

    // The starting state, pinned: the singleton loads without the backend
    // having opened tailscaled's socket, and reads as a machine that has not
    // reported in yet rather than as one that is connected and unblocked.
    void tailscaleSingletonLoadsAndStartsInNoState()
    {
        QQmlEngine engine;
        engine.setImportPathList({importPath()});
        auto *ts = engine.singletonInstance<QObject *>("C7", "Tailscale");
        QVERIFY2(ts, "module C7 loaded but its Tailscale singleton did not");
        QCOMPARE(ts->property("state").toInt(), 0); // State::NoState
        QCOMPARE(ts->property("exitNodeBlocked").toBool(), false);
        QVERIFY(ts->property("peers").value<QAbstractItemModel *>() != nullptr);
        QVERIFY(ts->property("exitNodes").value<QAbstractItemModel *>() != nullptr);
    }
};

C7_TEST_MAIN(TestModule)
#include "tst_module.moc"
