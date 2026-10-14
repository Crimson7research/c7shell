#include "core/version.h"

#include <QtCore/QFileInfo>
#include <QtQml/QQmlEngine>
#include "testing/testmain.h"

#include <QtTest/QTest>

// `import C7` resolves from one module directory alone, the way the shell finds
// the installed one. That directory is the build tree's (C7_QML_IMPORT_PATH,
// compiled in), or an installed tree named by the variable of the same name.
// It is the only import path, so no other copy of C7 can stand in for it. That
// also rules out `import QtQml`, so the test reads the singleton from C++
// rather than through a QML document.
class TestModule : public QObject {
    Q_OBJECT

private slots:
    void buildSingletonReportsTheLibraryVersion()
    {
        const QString importPath =
            qEnvironmentVariable("C7_QML_IMPORT_PATH", QStringLiteral(C7_QML_IMPORT_PATH));
        QQmlEngine engine;
        engine.setImportPathList({importPath});
        auto *build = engine.singletonInstance<QObject *>("C7", "Build");
        // Qt reports nothing here, so say which half is broken: the module
        // directory, or loading the plugin and its Build singleton from it.
        QVERIFY2(build, QFileInfo::exists(importPath + QStringLiteral("/C7/qmldir"))
                            ? "C7/qmldir exists, but its plugin or Build singleton did not load"
                            : "module C7 is not installed: no C7/qmldir under the import path");
        QCOMPARE(build->property("version").toString(), c7::core::version());
    }
};

C7_TEST_MAIN(TestModule)
#include "tst_module.moc"
