// A test that dies with a PrivateBus alive: prints the daemon's pid, then
// kills itself, so no destructor runs. tst_privatebus checks the daemon goes.
// SIGKILL rather than abort(): the same death, without a core dump.
#include "testing/privatebus.h"
#include "testing/testmain.h"

#include <QtCore/QCoreApplication>

#include <csignal>
#include <cstdio>

int main(int argc, char *argv[])
{
    c7::testing::isolateFromHost();
    QCoreApplication app(argc, argv);
    c7::testing::PrivateBus bus;
    if (!bus.isRunning()) {
        std::fprintf(stderr, "%s\n", qPrintable(bus.error()));
        return 1;
    }
    std::printf("%lld\n", static_cast<long long>(bus.pid()));
    std::fflush(stdout);
    std::raise(SIGKILL);
}
