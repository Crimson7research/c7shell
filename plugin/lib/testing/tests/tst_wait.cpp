#include "testing/testmain.h"
#include "testing/wait.h"

#include <QtCore/QElapsedTimer>
#include <QtCore/QTimer>
#include <QtTest/QTest>

using c7::testing::kWaitBound;
using c7::testing::waitUntil;

class TestWait : public QObject {
    Q_OBJECT

private slots:
    void returnsAtOnceWhenAlreadyTrue() { QVERIFY(waitUntil([] { return true; })); }

    void runsTheEventLoopUntilTheConditionHolds()
    {
        bool fired = false;
        QTimer::singleShot(0, this, [&] { fired = true; });
        QVERIFY(waitUntil([&] { return fired; }));
    }

    void givesUpAtTheBoundItWasGiven()
    {
        // The bound is an upper limit, never a delay a passing test waits out.
        // Half the default bound is far above 20 ms on any machine, and far
        // below what ignoring the given bound would cost.
        QElapsedTimer t;
        t.start();
        QVERIFY(!waitUntil([] { return false; }, std::chrono::milliseconds(20)));
        QVERIFY(t.elapsed() < kWaitBound.count() / 2);
    }

    void theDefaultBoundIsGenerous() { QVERIFY(kWaitBound >= std::chrono::seconds(10)); }
};

C7_TEST_MAIN(TestWait)
#include "tst_wait.moc"
