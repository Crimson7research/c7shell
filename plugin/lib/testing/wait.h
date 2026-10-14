#pragma once

#include <QtTest/QTest>

#include <chrono>

namespace c7::testing {

// Long enough that no machine, however loaded, reaches it while the code under
// test works. A passing test never waits it out; only a broken one does.
inline constexpr std::chrono::milliseconds kWaitBound{std::chrono::seconds(10)};

// Run the event loop until `done()` holds or `bound` passes, and say which.
// Never a sleep: the test goes on the moment the condition holds.
template <typename Predicate>
bool waitUntil(Predicate done, std::chrono::milliseconds bound = kWaitBound)
{
    // The int overload: the QDeadlineTimer one needs Qt 6.7, the build asks 6.5.
    return QTest::qWaitFor(done, int(bound.count()));
}

} // namespace c7::testing
