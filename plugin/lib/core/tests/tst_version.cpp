#include "core/version.h"

#include "testing/testmain.h"

#include <QtTest/QTest>

// The library reports the version the build was configured with, not a
// literal that drifts from it. C7_EXPECTED_VERSION is the CMake project
// version, handed to this test separately from the library.
class TestVersion : public QObject {
    Q_OBJECT

private slots:
    void reportsTheConfiguredVersion()
    {
        QCOMPARE(c7::core::version(), QStringLiteral(C7_EXPECTED_VERSION));
    }
};

C7_TEST_MAIN(TestVersion)
#include "tst_version.moc"
