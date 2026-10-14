#pragma once

#include <QtCore/QString>
#include <QtCore/QStringList>
#include <QtTest/QTest>

namespace c7::testing {

// Cut this process off from the machine it runs on. Every environment
// variable goes except the few in isolationKeeps(); then the D-Bus session and
// system bus addresses point at a socket that does not exist, and HOME, PATH,
// TMPDIR and the XDG directories at a fresh private directory, so a library
// that reaches for the host's buses, sockets, files or programs fails instead
// of quietly using them. Safe to call again. Exits the process if it cannot set
// up the private directory: running against the host instead is the one thing
// it must not do.
void isolateFromHost();

// The private directory isolateFromHost() made.
QString hostIsolationRoot();

// What survives isolation: names, or prefixes ending in '*'. Locale, terminal,
// Qt's and QtTest's logging knobs, and what coverage and sanitizers read.
QStringList isolationKeeps();
// What isolation sets itself.
QStringList isolationSets();

} // namespace c7::testing

// The main of every plugin test: QtTest's own, after isolation. Isolation runs
// as this file's last static initialiser, before main and before QtTest's
// initMain(); a test's own globals must not touch the host.
#define C7_TEST_MAIN(TestObject)                                                                   \
    [[maybe_unused]] static const bool c7IsolatedFromHost =                                        \
        (c7::testing::isolateFromHost(), true);                                                    \
    QTEST_GUILESS_MAIN(TestObject)
